# Get logos
wget https://github.com/PikaOS-Linux/pika-branding/raw/main/logos/pika-mono-small.svg -O ./basefiles/logos/pika-logo-duotone.svg
wget https://github.com/PikaOS-Linux/pika-branding/raw/main/logos/pika-logo-text-dark.svg -O ./basefiles/logos/pika-logo-text-dark.svg
wget https://github.com/PikaOS-Linux/pika-branding/raw/main/logos/pika-logo-text.svg -O ./basefiles/logos/pika-logo-text.svg
wget https://github.com/PikaOS-Linux/pika-branding/raw/main/logos/pika-logo.svg -O ./basefiles/logos/pika-logo.svg

# Clone Upstream
cd ./basefiles

# Get build deps
apt-get build-dep ./ -y

# Build package
dpkg-buildpackage --no-sign

# Move the debs to output
cd ../
mkdir -p ./output
mv ./*.deb ./output/
