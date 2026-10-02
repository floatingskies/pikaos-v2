# We just want ubuntu with our apt packages already included
# Bump for rebuild on 01/07/2024 16:51 UTC 
FROM ubuntu:23.10
RUN apt-get -y update
RUN apt-get install wget -y
# Install Pika Apt Sources
RUN wget https://ppa.pika-os.com/dists/pikauwu/pika-sources.deb
RUN DEBIAN_FRONTEND=noninteractive apt-get install ./pika-sources.deb --yes --option Acquire::Retries=5 --option Acquire::http::Timeout=100 --option Dpkg::Options::="--force-confnew"
RUN rm -rf ./pika-sources.deb
RUN DEBIAN_FRONTEND=noninteractive apt-get -y update
RUN DEBIAN_FRONTEND=noninteractive apt-get -y upgrade --allow-downgrades
RUN apt-get -y install software-properties-common sudo git bc gpg gpg-agent bison build-essential ccache cmake cpio fakeroot flex git kmod libelf-dev libncurses5-dev libssl-dev lz4 qtbase5-dev rsync schedtool wget zstd tar devscripts dh-make rpm2cpio -y
RUN apt-get -y install dpkg-sig libfdk-aac-dev -y
RUN ln -fs /usr/share/zoneinfo/America/New_York /etc/localtime
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y tzdata
