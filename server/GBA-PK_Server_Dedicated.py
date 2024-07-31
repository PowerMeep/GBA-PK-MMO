import logging
import os
import re
import socket
from threading import Thread
import time

# Load ENVs
logging_level = logging.getLevelName(os.environ.get('LOGGING_LEVEL', 'WARNING'))
server_nick = os.environ.get('SERVER_NAME', 'servname')[:8]
ping_time = int(os.environ.get('PING_TIME', '5'))
missed_pongs = int(os.environ.get('MAX_MISSED_PONGS', '2'))
supported_games = os.environ.get('SUPPORTED_GAMES', 'BPR1, BPR2, BPG1, BPG2')
max_players = int(os.environ.get('MAX_PLAYERS', '9'))
port = int(os.environ.get('PORT', '4096'))

server_nick = server_nick + ' '*(8-len(server_nick))

# Get Logger
logging.basicConfig(level=logging_level, format='[%(asctime)s][%(name)s][%(levelname)s] %(message)s')
logger = logging.getLogger('Server')

# Report ENVs
logger.warning(f'Logging level set to {logging_level}')
logger.warning(f'Server Name set to "{server_nick}"')
logger.warning(f'Ping Time set to {ping_time} seconds')
logger.warning(f'Max Missed Pongs set to {missed_pongs}')
logger.warning(f'Supported Games set to {supported_games}')
logger.warning(f'Max Players set to {max_players}')

# Server management packet types
PACKET_TYPE_START = 'STRT'
PACKET_TYPE_DENY  = 'DENY'
PACKET_TYPE_EXIT  = 'EXIT'

# Client packet types
PACKET_TYPE_JOIN     = 'JOIN'
PACKET_TYPE_POS      = 'SPOS'
PACKET_TYPE_PING     = 'PING'
PACKET_TYPE_PONG     = 'PONG'
PACKET_TYPE_PINGPONG = 'PNPN'

# Deny reasons
MIN_SUPPORTED_CLIENT_VERSION = 1020
SUPPORTED_CHARS = re.compile('[a-zA-Z0-9._ -]+')
PACKET_VAL_SERVER_FULL = 'FULL'
PACKET_VAL_NAME_TAKEN  = 'NAME'
PACKET_VAL_MALFORMED   = 'MALF'
PACKET_VAL_GAME        = 'GAME'
PACKET_VAL_BAD_CHARS   = 'CHRS'

# Packet constants
MAP_ID_PAYLOAD_INDEX = 21
MAP_ENTRANCE_TYPE_NORMAL  = '0'
MAP_ENTRANCE_TYPE_FADEOUT = '1'  # This doesn't seem to update much
# Apparently, this list goes up to 10?

# Facing Direction
DIRECTION_WEST  = '1'
DIRECTION_EAST  = '2'
DIRECTION_NORTH = '3'
DIRECTION_SOUTH = '4'

# Misc Constants
KEY_WALKABLE     = 'walkable'
KEY_NOT_WALKABLE = 'not walkable'

# Runtime Variables
running = True
clients_by_nick = {}
clients_by_map_id = {}
walkable_exits_by_map_id = {}
unwalkable_exits_by_map_id = {}


def add_possible_adjacency(map_id, prev_map_id, entrance_type):
    """
    Attempts to mark two maps as adjacent AND visible to one another.
    Used for determining which players might be able to see one another.

    The entrance_type field is not reliable. It is always set to 0 when walking into a new map,
    but it is not always set to 1 when walking through a door. As a workaround, I've implemented a non-walkable map.
    If an area is known to be non-walkable, then it won't be marked as walkable. Inversely, if a transition was previously
    marked as walkable, presumably erroneously, then a non-walkable transition will remove that.
    - Walking to new map. Flag always set to 0.
    - Entering a building. Flag set to 1 _after_ the first time.
    - Fainting teleports you inside Pokemon Center. Flag not set to 1.
    - Using "Fly" - Teleports you outside a Pokemon Center. Flag set to 1.
    - Using "Teleport" - ??? Probably inside Pokemon Center?

    :param map_id: The map a player is currently on.
    :param prev_map_id: The map the player was previously on.
    :param entrance_type: The transition that occurred between the two maps.
    :return:
    """
    if prev_map_id in unwalkable_exits_by_map_id.get(map_id, {})\
            or map_id in unwalkable_exits_by_map_id.get(prev_map_id, {}):
        logger.info(f'Map {map_id} is already unwalkable from {prev_map_id}, skipping')
        return
    if entrance_type == MAP_ENTRANCE_TYPE_NORMAL:
        if prev_map_id not in walkable_exits_by_map_id.get(map_id, {}):
            logger.info(f'Marking {map_id} as walkable from {prev_map_id}')
            walkable_exits_by_map_id.setdefault(map_id, {})[prev_map_id] = {}
        if map_id not in walkable_exits_by_map_id.get(prev_map_id, {}):
            logger.info(f'Marking {prev_map_id} as walkable from {map_id}')
            walkable_exits_by_map_id.setdefault(prev_map_id, {})[map_id] = {}
    elif entrance_type == MAP_ENTRANCE_TYPE_FADEOUT:
        if prev_map_id in walkable_exits_by_map_id.get(map_id, {}):
            del(walkable_exits_by_map_id[map_id][prev_map_id])
        if map_id in walkable_exits_by_map_id.get(prev_map_id, {}):
            del(walkable_exits_by_map_id[prev_map_id][map_id])
        logger.info(f'Marking {map_id} as unwalkable from {prev_map_id}')
        logger.info(f'Marking {prev_map_id} as unwalkable from {map_id}')
        unwalkable_exits_by_map_id.setdefault(map_id, {})[prev_map_id] = {}
        unwalkable_exits_by_map_id.setdefault(prev_map_id, {})[map_id] = {}
    else:
        logger.warning(f'Unknown entrance type: {entrance_type}')


class Client:
    def __init__(self,
                 sock: socket.socket,
                 addr):
        self.sock: socket.socket = sock
        self.sock.settimeout(10)
        self.latency = '0000'
        self.addr = addr
        self.version = MIN_SUPPORTED_CLIENT_VERSION
        self.nick = '0000'
        self.logger = logger
        self.unresponded_pings = 0
        self.last_spos = None
        self.map_id = None
        self.running = True
        self.thread = None

    def setup(self) -> bool:
        packet = self.read_one_message()
        if packet is None:
            self.logger.warning(f'Client {self.addr} turned away, no initial packet received.')
            return False

        join = packet[8:12]
        if not join == PACKET_TYPE_JOIN:
            self.logger.warning(f'Client {self.addr} turned away, initial packet malformed.')
            self.send_packet(PACKET_TYPE_DENY, PACKET_VAL_MALFORMED)
            return False

        # Version check goes first because once we know this, we know what to expect from this client.
        self.version = int(packet[12:16])
        if self.version < MIN_SUPPORTED_CLIENT_VERSION:
            self.logger.warning(f'Client {self.addr} turned away, client version outdated '
                                f'({self.version} < {MIN_SUPPORTED_CLIENT_VERSION}).')
            self.send_packet(PACKET_TYPE_DENY, str(MIN_SUPPORTED_CLIENT_VERSION))
            return False

        # nick     type version gameid payload                                     U
        # asdfghjk JOIN 1001    BPR1   100020002000100101000100000100000020001999F U
        self.nick = packet[:8]
        game = packet[16:20]

        if not re.match(SUPPORTED_CHARS, self.nick):
            self.logger.warning(f'Client {self.addr} turned away, name "{self.nick}" contained invalid characters.')
            self.send_packet(PACKET_TYPE_DENY, PACKET_VAL_BAD_CHARS)
            return False

        self.logger = logging.getLogger(self.nick)
        self.logger.warning(f'Client {self.addr} setting up.')

        if game not in supported_games:
            self.logger.warning(f'Client {self.addr} turned away, game not supported. '
                                f'{game} not in {supported_games}')
            self.send_packet(PACKET_TYPE_DENY, PACKET_VAL_GAME)
            return False

        # Look for available seat
        if self.nick in clients_by_nick:
            other = clients_by_nick.get(self.nick)
            if self.addr[0] == other.addr[0]:
                self.logger.warning(f'Client {self.addr} is reconnecting.')
            else:
                self.logger.warning(f'Client {self.addr} turned away, '
                                    f'the name "{self.nick}" is in use by someone else.')
                self.send_packet(PACKET_TYPE_DENY, PACKET_VAL_NAME_TAKEN)
                return False
        elif len(clients_by_nick) >= max_players is None:
            self.logger.warning(f'Client {self.addr} turned away, '
                                f'the server is full. ({len(clients_by_nick)} / {max_players})')
            self.send_packet(PACKET_TYPE_DENY, PACKET_VAL_SERVER_FULL)
            return False

        self.send_packet(
            PACKET_TYPE_START
        )
        clients_by_nick[self.nick] = self
        self.logger.warning(f'Adding client {self.addr} -> "{self.nick}"')
        # The payload is shifted to the right here
        self.update_positions(packet[:8], packet[20:])
        report()
        return True

    def start(self):
        self.thread = Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        try:
            if not self.setup():
                self.disconnect()
                return
            self.logger.info(f'Listening for messages.')
            while self.running:
                packet = self.read_one_message()
                self.on_raw_packet(packet)
        except IOError as e:
            self.logger.error(e)
        finally:
            self.teardown()

    def read_one_message(self):
        try:
            raw = self.sock.recv(64)
            if raw is None or len(raw) == 0:
                raise IOError(f'{self.addr} Socket closed.')
            return raw.decode('UTF-8')
        except socket.timeout:
            raise IOError(f'{self.addr} Timed out.')

    def on_raw_packet(self, packet):
        packet = str(packet)
        self.logger.debug(f'>>> {packet}')
        if len(packet) < 64:
            self.logger.warning('Received packet was too short.')
            return

        the_letter_u = packet[63]
        if not the_letter_u == 'U':
            self.logger.error('Malformed packet did not end with a U.')
            return

        packet_type = packet[8:12]
        if packet_type == PACKET_TYPE_POS:
            self.update_positions(packet[:8], packet[12:])
        elif packet_type == PACKET_TYPE_PONG:
            index_of_padding = packet.find('F', 12)
            if index_of_padding >= 0:
                try:
                    # Subtract timestamp in message from current millis
                    # Bound to 4-digit number between 0 and 9999
                    time_ping_sent = int(packet[12:index_of_padding])
                    now = round(time.time() * 1000)
                    latency = now - time_ping_sent
                    self.latency = f'{max(
                        0, min(
                            latency,
                            9999
                        )
                    ):04}'
                    self.send_packet(PACKET_TYPE_PINGPONG, self.latency)
                except ValueError:
                    self.logger.warning(f'Received packet {packet_type} did not have a numeric timestamp.')
            self.unresponded_pings = 0
        else:
            recipient = packet[12:20]
            if recipient in clients_by_nick:
                clients_by_nick[recipient].send_raw(packet)
            else:
                self.logger.warning(f'Received packet {packet_type} was for unknown player {recipient}.')

    def update_positions(self, nick, payload):
        map_id            = payload[MAP_ID_PAYLOAD_INDEX:MAP_ID_PAYLOAD_INDEX+6]
        map_id_prev       = payload[MAP_ID_PAYLOAD_INDEX+6:MAP_ID_PAYLOAD_INDEX+12]
        map_entrance_type = payload[MAP_ID_PAYLOAD_INDEX+12]
        self.logger.debug(f'{payload} > {map_id}')
        if map_id != self.map_id:

            if self.map_id is not None:
                clients_by_map_id[self.map_id].remove(self)
                new_neighbors = set(walkable_exits_by_map_id.get(map_id, {}))
                new_neighbors.add(map_id)
                self.distribute_exit_to_neighbors(new_neighbors)
                add_possible_adjacency(map_id, self.map_id, map_entrance_type)

            clients_by_map_id.setdefault(map_id, []).append(self)
            self.map_id = map_id

            self.get_visible_players()

        # Inject latency from most recent pingpong
        scrubbed_packet = nick + PACKET_TYPE_POS + self.latency + payload[4:]
        scrubbed_packet = scrubbed_packet + ('U' * (64 - len(scrubbed_packet)))

        self.last_spos = scrubbed_packet
        self.distribute(scrubbed_packet)

    def distribute(self, packet):
        """
        Send this to all other players.
        :param packet:
        :return:
        """
        neighbors = list(walkable_exits_by_map_id.get(self.map_id, {}))
        neighbors.append(self.map_id)
        for map_id in neighbors:
            for client in list(clients_by_map_id.get(map_id, [])):
                if client == self:
                    continue
                client.send_raw(packet)

    def get_visible_players(self):
        neighbors = list(walkable_exits_by_map_id.get(self.map_id, {}))
        neighbors.append(self.map_id)
        for map_id in neighbors:
            for client in list(clients_by_map_id.get(map_id, [])):
                if client == self:
                    continue
                self.send_raw(client.last_spos)

    def send_raw(self, message):
        try:
            self.logger.debug(f'<<< {message}')
            self.sock.send(message.encode('UTF-8'))
        except IOError:
            self.logger.error('Could not send message, socket closed.')
            self.teardown()

    def send_packet(self,
                    packet_type,
                    payload=""):
        packet = (
            str(server_nick) +
            str(packet_type) +
            str(payload)
        )
        # Pad to 64 characters with F's
        packet = packet + ('F' * (63 - len(packet))) + 'U'
        self.send_raw(packet)

    def send_exit_packet_from(self, client):
        self.send_raw(f'{client.nick}{PACKET_TYPE_EXIT}{"0" * 50}FU')

    def distribute_exit_to_neighbors(self, difference=None):
        neighbors = set(walkable_exits_by_map_id.get(self.map_id, {}))
        neighbors.add(self.map_id)
        if difference is not None:
            neighbors = neighbors.difference(difference)
        for map_id in neighbors:
            for client in clients_by_map_id.get(map_id, []):
                if client == self:
                    continue
                if difference is not None:
                    self.send_exit_packet_from(client)
                client.send_exit_packet_from(self)

    def ping(self):
        if self.unresponded_pings >= missed_pongs:
            self.logger.warning('Disconnecting due to inactivity.')
            self.disconnect()
            self.teardown()
        else:
            self.unresponded_pings += 1
            # This should function like a ping and stop the client from timing out so aggressively
            self.send_packet(
                PACKET_TYPE_PING,
                str(round(time.time() * 1000))
            )

    def disconnect(self):
        self.running = False
        self.sock.shutdown(socket.SHUT_RDWR)
        self.sock.close()

    def teardown(self):
        self.running = False
        self.logger.warning(f'Removing client {self.addr}')
        if self.nick in clients_by_nick:
            del(clients_by_nick[self.nick])
            self.distribute_exit_to_neighbors()
        if self.map_id in clients_by_map_id:
            clients_by_map_id[self.map_id].remove(self)
        report()


def on_new_connection(s, addr):
    logger.warning(f'New connection from {addr}')
    Client(s, addr).start()


def ping_loop():
    while running:
        time.sleep(ping_time)
        for client in list(clients_by_nick.values()):
            client.ping()


def disconnect_all():
    logger.warning('Cleaning up')
    for client in list(clients_by_nick.values()):
        client.disconnect()


def report():
    logger.warning(f'TOTAL PLAYERS: {len(clients_by_nick)} / {max_players}')


def start_server():
    global running
    dq_thread = Thread(target=ping_loop, daemon=True)
    dq_thread.start()

    ss = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    host = '0.0.0.0'
    logger.warning('Binding to port {}:{}'.format(host, port))
    ss.bind((host, port))
    ss.listen(1)
    try:
        logger.warning('Listening for connections...')
        while running:
            s, addr = ss.accept()
            on_new_connection(s, addr)
    except (KeyboardInterrupt, SystemExit):
        disconnect_all()
    finally:
        running = False
        ss.close()


if __name__ == '__main__':
    start_server()
