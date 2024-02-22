import logging
import os
import re
import socket
from threading import Thread
from time import sleep

# Load ENVs
logging_level = logging.getLevelName(os.environ.get('LOGGING_LEVEL', 'WARNING'))
server_nick = os.environ.get('SERVER_NAME', 'servname')[:8]
ping_time = int(os.environ.get('PING_TIME', '5'))
missed_pongs = int(os.environ.get('MAX_MISSED_PONGS', '2'))
supported_games = os.environ.get('SUPPORTED_GAMES', 'BPR1, BPR2, BPG1, BPG2')
max_players = int(os.environ.get('MAX_PLAYERS', '5'))

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
PACKET_TYPE_JOIN = 'JOIN'
PACKET_TYPE_POS  = 'SPOS'
PACKET_TYPE_PING = 'GPOS'
PACKET_TYPE_PONG = 'GPOS'

# Deny reasons
MIN_SUPPORTED_CLIENT_VERSION = 1015
SUPPORTED_CHARS = re.compile('[a-zA-Z0-9._ -]+')
PACKET_VAL_SERVER_FULL = 'FULL'
PACKET_VAL_NAME_TAKEN  = 'NAME'
PACKET_VAL_MALFORMED   = 'MALF'
PACKET_VAL_GAME        = 'GAME'
PACKET_VAL_BAD_CHARS   = 'CHRS'

# Packet constants
MAP_ENTRANCE_TYPE_NORMAL  = '0'
MAP_ENTRANCE_TYPE_FADEOUT = '1'  # This doesn't seem to update much
# Apparently, this list goes up to 10?

# Facing Direction
DIRECTION_WEST  = '1'
DIRECTION_EAST  = '2'
DIRECTION_NORTH = '3'
DIRECTION_SOUTH = '4'

# Misc Constants
PORT      = 4096
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

    The `entrance_type` flag is not reliably set at this time and may be set to WALKABLE incorrectly.
    To mitigate this, a previously WALKABLE transition may be marked as UNWALKABLE by a future packet.

    HOWEVER, there is a bug here related to teleporting, which cause CORRECTLY marked areas to be
    marked as permanently unwalkable until the next server reboot.

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
        self.sock.settimeout(5)
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

        join = packet[16:20]
        if not join == PACKET_TYPE_JOIN:
            self.logger.warning(f'Client {self.addr} turned away, initial packet malformed.')
            self.send_packet(PACKET_TYPE_DENY, PACKET_VAL_MALFORMED)
            return False

        # Version check goes first because once we know this, we know what to expect from this client.
        self.version = int(packet[8:12])
        if self.version < MIN_SUPPORTED_CLIENT_VERSION:
            self.logger.warning(f'Client {self.addr} turned away, client version outdated '
                                f'({self.version} < {MIN_SUPPORTED_CLIENT_VERSION}).')
            self.send_packet(PACKET_TYPE_DENY, str(MIN_SUPPORTED_CLIENT_VERSION))
            return False

        # nick     version gameid type payload                                      U
        # asdfghjk 1001    BPR1   JOIN 1000 20002000100101000100000100000020001999F U
        self.nick = packet[:8]
        game = packet[12:16]

        if not re.match(SUPPORTED_CHARS, self.nick):
            self.logger.warning(f'Client {self.addr} turned away, name "{self.nick}" contained invalid characters.')
            self.send_packet(PACKET_TYPE_DENY, PACKET_VAL_BAD_CHARS)
            return False

        self.logger = logging.getLogger(self.nick)
        self.logger.warning(f'Client {self.addr} setting up.')

        if game not in supported_games:
            self.logger.warning(f'Client {self.addr} turned away, game not supported. '
                                f'{game} not in {supported_games}')
            self.send_packet(PACKET_TYPE_DENY, str(MIN_SUPPORTED_CLIENT_VERSION))
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
        if len(packet) < 64:
            self.logger.warning(packet)
            return

        sender            = packet[0:8]
        recipient         = packet[8:16]
        packet_type       = packet[16:20]
        packet_val        = packet[20:24]
        current_x         = packet[24:28]
        current_y         = packet[28:32]
        facing_2          = packet[32:35]
        extra_1           = packet[35:38]
        gender            = packet[38]
        extra_3           = packet[39]
        extra_4           = packet[40]
        map_id            = packet[41:47]
        map_id_prev       = packet[47:53]
        map_entrance_type = packet[53]
        start_x           = packet[54:58]
        start_y           = packet[58:62]
        the_letter_u      = packet[63]

        # self.logger.warning(f'{packet_type}')
        if packet_type == PACKET_TYPE_POS:
            if map_id != self.map_id:

                if self.map_id is not None:
                    clients_by_map_id[self.map_id].remove(self)
                    new_neighbors = set(walkable_exits_by_map_id.get(map_id, {}))
                    new_neighbors.add(map_id)
                    self.distribute_exit_to_neighbors(new_neighbors)
                    add_possible_adjacency(map_id, self.map_id, map_entrance_type)

                clients_by_map_id.setdefault(map_id, []).append(self)
                self.map_id = map_id

            if recipient == server_nick:
                scrubbed_packet = packet
            else:
                scrubbed_packet = packet[:8] + server_nick + packet[16:]

            self.last_spos = scrubbed_packet
            self.distribute(scrubbed_packet)

        elif packet_type == PACKET_TYPE_PONG:
            self.logger.debug('Received PONG')
            self.unresponded_pings = 0
        elif recipient in clients_by_nick:
            clients_by_nick[recipient].send_raw(packet)
        else:
            self.logger.warning(packet)

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
                # Fudge that this packet is INTENDED for this recipient.
                # May not be necessary. Further analysis needed.
                modded_packet = packet[:8] + client.nick + packet[16:]
                client.send_raw(modded_packet)

    def send_raw(self, message):
        try:
            self.logger.debug('Sending message')
            self.sock.send(message.encode('UTF-8'))
        except IOError:
            self.logger.error('Could not send message, socket closed.')
            self.teardown()

    def send_packet(self,
                    packet_type,
                    payload="0000"):
        self.send_raw(
            str(server_nick) +
            str(self.nick) +
            str(packet_type) +
            str(payload) +
            "11111111111111111111111111111111111111FU"
        )

    def send_exit_packet_from(self, client):
        self.send_raw(f'{client.nick}{self.nick}{PACKET_TYPE_EXIT}{"0" * 42}FU')

    def distribute_exit_to_neighbors(self, difference=None):
        self.logger.debug('Sending EXIT packet')
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
            self.logger.warning(f'Disconnecting due to inactivity.')
            self.disconnect()
            self.teardown()
        else:
            self.logger.debug(f'Sending PING.')
            self.unresponded_pings += 1
            # This should function like a ping and stop the client from timing out so aggressively
            self.send_packet(
                PACKET_TYPE_PING,
                "1111"
            )

    def disconnect(self):
        self.running = False
        self.sock.shutdown(socket.SHUT_RDWR)
        self.sock.close()

    def teardown(self):
        self.running = False
        self.logger.warning(f'Removing client {self.addr} -> "{self.nick}"')
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
        sleep(ping_time)
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
    logger.warning('Binding to port {}:{}'.format(host, PORT))
    ss.bind((host, PORT))
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
