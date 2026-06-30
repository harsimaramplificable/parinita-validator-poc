# Create Project directory
mkdir -p ~/besu-qbft-lab && cd ~/besu-qbft-lab && pwd

cd ~/besu-qbft-lab && cat > qbftConfigFile.json <<'EOF'
{
  "genesis": {
    "config": {
      "chainId": 1337,
      "berlinBlock": 0,
      "qbft": {
        "blockperiodseconds": 0,
        "epochlength": 30000,
        "requesttimeoutseconds": 4,
        "emptyblockperiodseconds": 9999999
      }
    },
    "nonce": "0x0",
    "timestamp": "0x58ee40ba",
    "gasLimit": "0x1C9C380",
    "difficulty": "0x1",
    "mixHash": "0x63746963616c2062797a616e74696e65206661756c7420746f6c6572616e6365",
    "coinbase": "0x0000000000000000000000000000000000000000",
    "alloc": {
      "fe3b557e8fb62b89f4916b721be55ceb828dbd73": {
        "privateKey": "8f2a55949038a9610f50fb23b5883af3b4ecb3c3bb792cbcefbd1542c692be63",
        "comment": "Dev account 1 - PUBLICLY KNOWN KEY, lab use only. privateKey field is ignored by Besu.",
        "balance": "0xad78ebc5ac6200000"
      },
      "627306090abaB3A6e1400e9345bC60c78a8BEf57": {
        "privateKey": "c87509a1c067bbde78beb793e6fa76530b6382a4c0241e5e4a9ec0a0f44dc0d3",
        "comment": "Dev account 2 - PUBLICLY KNOWN KEY, lab use only. privateKey field is ignored by Besu.",
        "balance": "0xad78ebc5ac6200000"
      },
      "f17f52151EbEF6C7334FAD080c5704D77216b732": {
        "privateKey": "ae6ae8e5ccbfb04590405997ee2d52d2b330726137b875053c36d94e974d162f",
        "comment": "Dev account 3 - PUBLICLY KNOWN KEY, lab use only. privateKey field is ignored by Besu.",
        "balance": "0xad78ebc5ac6200000"
      }
    }
  },
  "blockchain": {
    "nodes": {
      "generate": true,
      "count": 4
    }
  }
}
EOF
echo "Written. Validating:" && python3 -c "import json; json.load(open('qbftConfigFile.json')); print('qbftConfigFile.json is valid JSON')"
