# Java Installation
sudo apt update
sudo apt install -y openjdk-25-jdk
java -version
# Expected: openjdk version "25. x. x"

# Besu Installation
# Check latest version at: https://github.com/hyperledger/besu/releases
export BESU_VERSION="26.6.1"

# Download
wget https://github.com/hyperledger/besu/releases/download/${BESU_VERSION}/besu-${BESU_VERSION}.tar.gz

# Extract and install
tar xzf besu-${BESU_VERSION}.tar.gz
sudo mv besu-${BESU_VERSION} /opt/besu-${BESU_VERSION}
sudo ln -sfn /opt/besu-${BESU_VERSION} /opt/besu

# Add to PATH
echo 'export PATH=/opt/besu/bin:$PATH' >> ~/.bashrc
export PATH=/opt/besu/bin:$PATH

# IMPORTANT: unset BESU_VERSION env var (it interferes with the CLI)
unset BESU_VERSION
sed -i '/BESU_VERSION/d' ~/.bashrc

# Verify
besu --help | head -3
# Expected: Usage: besu [OPTIONS] [COMMAND]

