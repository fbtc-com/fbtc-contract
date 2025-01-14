# FBTC

This repository contains the smart contracts source code for [Ignition $FBTC](https://fbtc.com/) bridge.

# Development

## Compile & Run Test

```sh
# Install lib/forge-std
forge init --force --no-commit
# or
forge install foundry-rs/forge-std@v1.7.6 --no-commit

# Install openzeppelin-contracts
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-commit
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.0.2 --no-commit

# Compile
forge compile

# Run test
forge test
```

## Deploy

1. Configure RPC and blockchain explorer endpoint URL.

    `.env`
    ```diff
    + SNOIC_RPC=https://sonic.drpc.org
    + SNOIC_TOKEN=CJRB5MPKIUWA95EJJYCA5MA1ATV1NTK76K
    ```

    `foundry.toml`
    ```diff
    [rpc_endpoints]
    + sonic = "${SNOIC_RPC}"
    + sonic = {key = "${SNOIC_TOKEN}", url="https://api.sonicscan.org/api?", chain=146}
    ```

2. Deploy the [FBTCFactory](./script/FBTCFactory.sol) if it is not deployed yet.

    ```
    forge create FBTCFactory \
        --chain <chain> \
        --account <account> \
        --verify
    ```

3. Create an address configuration file in `script/deployments/<your_config>.json`. Refer [prod_sonic.json](./script/deployments/prod_sonic.json) as an example.

4. Run the deployment script.
    ```
    forge script script/Deploy.s.sol \
        --tc DeployScript \
        -s `cast calldata "deployOneStep(string,string,string)" <chain> <your_config> <tag>` \
        --account <account> \
        --chain <chain> \
        --verify \
        --broadcast \
        --slow
    ```
    If the above command runs successfully, the deployed address will be saved in the `script/deployments/addresses/<tag>_<your_config>_<chain>.json` file.
