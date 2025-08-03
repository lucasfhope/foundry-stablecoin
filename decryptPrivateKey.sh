#!/bin/bash


######################################################
# source ./decryptPrivateKey.sh
# to set the PRIVATE_KEY in the current shell.
######################################################
# unset PRIVATE_KEY
# to remove the PRIVATE_KEY from the current shell.
######################################################


# Use the first command line argument for account; default to "dev"
WALLET_ACCOUNT="${1:-dev}"
echo "Using wallet account: $WALLET_ACCOUNT"

# Decrypt the keystore using cast and export the PRIVATE_KEY
output=$(cast wallet decrypt-keystore "$WALLET_ACCOUNT")
PRIVATE_KEY=${output#*: }

if [ -z "$PRIVATE_KEY" ]; then
  echo "❌ Failed to decrypt the keystore."
  exit 1
fi

# Export the private key to the current shell (only works if sourced)
export PRIVATE_KEY="$PRIVATE_KEY"
echo "✅ PRIVATE_KEY has been set in the environment if sourced.\nRerun the script with 'source ./decryptPrivateKey.sh' to set the PRIVATE_KEY in the current shell."
