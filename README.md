# ICP Token Project (ckIdr and CkUsd)

This project implements two tokenization canisters on Internet Computer Protocol (ICP) - ckIdr and CkUsd - that can interact with a Motoko backend for transactions.

## Project Overview

The project consists of three main canisters:

1. **CkIDr**: A token canister implementing the ckIdr token
2. **CkUsd**: A token canister implementing the CkUsd token 
3. **token_manager**: A manager canister that coordinates interactions between tokens

## Features

- **Token Features**:
  - Minting and burning tokens (owner-only)
  - Token transfers between accounts
  - Balance tracking
  - Transaction history

- **Token Manager Features**:
  - Centralized token management
  - Account balance queries across tokens
  - Access control (owner-only operations)

## Getting Started

### Prerequisites

- [DFINITY Canister SDK](https://sdk.dfinity.org/docs/quickstart/local-quickstart.html)
- [Node.js](https://nodejs.org/) (>= 14.x)

### Installation

1. Clone the repository
2. Install dependencies:

```bash
npm install
```

### Deployment

To deploy the canisters locally:

```bash
dfx start --background
dfx deploy
```

### Initialization

After deployment, you need to initialize the token manager with the canister IDs:

```bash
dfx canister call token_manager initializeTokens "(principal \"$(dfx canister id CkIDr)\", principal \"$(dfx canister id CkUsd)\", principal \"$(dfx identity get-principal)\")"
```

## Usage Examples

### Checking Token Info

```bash
dfx canister call token_manager getTokenInfo "(\"CkIDr\")"
dfx canister call token_manager getAllTokensInfo
```

### Minting Tokens (Owner Only)

```bash
dfx canister call token_manager mint "(\"CkIDr\", principal \"YOUR_PRINCIPAL\", 1000000)"
```

### Checking Balances

```bash
dfx canister call token_manager getBalance "(principal \"YOUR_PRINCIPAL\", \"CkIDr\")"
dfx canister call token_manager getAllBalances "(principal \"YOUR_PRINCIPAL\")"
```

### Transferring Tokens

Regular transfer (from caller to recipient):
```bash
dfx canister call CkIDr transfer "(record { to = principal \"RECIPIENT_PRINCIPAL\"; amount = 10000; memo = null })"
```

Owner transfer (can transfer from any account):
```bash
dfx canister call token_manager ownerTransfer "(\"CkIDr\", principal \"FROM_PRINCIPAL\", principal \"TO_PRINCIPAL\", 10000)"
```

## Architecture

Each token canister is an instance of the same Token class, but with different initialization parameters. The token manager coordinates interactions between these tokens.

### Security Features

- Only the owner can mint or burn tokens
- Only the owner can perform transfers on behalf of other accounts
- Transaction history is maintained for all operations

## License

This project is licensed under the MIT License.

# `zap-x-icp`

Welcome to your new `zap-x-icp` project and to the Internet Computer development community. By default, creating a new project adds this README and some template files to your project directory. You can edit these template files to customize your project and to include your own code to speed up the development cycle.

To get started, you might want to explore the project directory structure and the default configuration file. Working with this project in your development environment will not affect any production deployment or identity tokens.

To learn more before you start working with `zap-x-icp`, see the following documentation available online:

- [Quick Start](https://internetcomputer.org/docs/current/developer-docs/setup/deploy-locally)
- [SDK Developer Tools](https://internetcomputer.org/docs/current/developer-docs/setup/install)
- [Motoko Programming Language Guide](https://internetcomputer.org/docs/current/motoko/main/motoko)
- [Motoko Language Quick Reference](https://internetcomputer.org/docs/current/motoko/main/language-manual)

If you want to start working on your project right away, you might want to try the following commands:

```bash
cd zap-x-icp/
dfx help
dfx canister --help
```

## Running the project locally

If you want to test your project locally, you can use the following commands:

```bash
# Starts the replica, running in the background
dfx start --background

# Deploys your canisters to the replica and generates your candid interface
dfx deploy
```

Once the job completes, your application will be available at `http://localhost:4943?canisterId={asset_canister_id}`.

If you have made changes to your backend canister, you can generate a new candid interface with

```bash
npm run generate
```

at any time. This is recommended before starting the frontend development server, and will be run automatically any time you run `dfx deploy`.

If you are making frontend changes, you can start a development server with

```bash
npm start
```

Which will start a server at `http://localhost:8080`, proxying API requests to the replica at port 4943.

### Note on frontend environment variables

If you are hosting frontend code somewhere without using DFX, you may need to make one of the following adjustments to ensure your project does not fetch the root key in production:

- set`DFX_NETWORK` to `ic` if you are using Webpack
- use your own preferred method to replace `process.env.DFX_NETWORK` in the autogenerated declarations
  - Setting `canisters -> {asset_canister_id} -> declarations -> env_override to a string` in `dfx.json` will replace `process.env.DFX_NETWORK` with the string in the autogenerated declarations
- Write your own `createActor` constructor
