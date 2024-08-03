# syntax=docker/dockerfile:1
FROM python:3.12-slim-bullseye

RUN apt-get update && apt-get upgrade -y

WORKDIR /app

COPY GBA-PK_Server_Dedicated.py .

ENV LOGGING_LEVEL="WARNING"
ENV SERVER_NAME="serv"
ENV PING_TIME="5"
ENV MAX_MISSED_PONGS="3"
ENV SUPPORTED_GAMES="BPR1, BPR2, BPG1, BPG2"
ENV MAX_PLAYERS="9"
ENV PORT="4096"

CMD ["python3", "GBA-PK_Server_Dedicated.py"]
