export RPC_URL=
export PRIVATE_KEY=
export OWNER_ADDRESS=
export BRIDGE_ADDRESS=

export OWNER_ADDRESS=
export BRIDGE_ADDRESS=

forge script FBTCScript --sig "deployFBTC()" --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY

export FBTC_ADDRESS=
export NEW_BRIDGE_ADDRESS=

forge script FBTCScript --sig "setBridge()" --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY

