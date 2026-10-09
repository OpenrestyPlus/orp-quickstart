FROM docker.elastic.co/beats/filebeat:8.10.1
USER root
COPY filebeat.yml /usr/share/filebeat/filebeat.yml
RUN chmod go-w /usr/share/filebeat/filebeat.yml
USER filebeat
