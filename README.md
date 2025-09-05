# IL Guard Mini

IL Guard Mini is a simple "Protect my LP" tool that helps reduce impermanent loss for liquidity providers on DragonSwap. The system automatically rebalances your UniV3 positions when prices move or volatility increases, so you don't have to constantly monitor and adjust your positions manually.

## What it does

- **One-tap Protection**: Just flip a switch to turn protection on or off for your liquidity positions
- **Real-time Dashboard**: See how much you're earning in fees, track estimated impermanent loss, and review recent actions
- **Automated Rebalancing**: The system watches price movements and adjusts your position ranges automatically when needed
- **Base Network Optimized**: Built specifically for Base network to keep gas costs low
- **Emergency Controls**: You can pause everything instantly if you need to take manual control

## Getting Started

### What you'll need

- Node.js version 18 or higher
- npm package manager
- Git

### Setting up the project

1. Get the code:

```bash
git clone <repository-url>
cd il-guard-mini
```

2. Install everything:

```bash
npm install
```

3. Set up your environment:

```bash
cp .env.example .env
```

Then edit the `.env` file with your specific configuration values.

### Development commands

```bash
# Build the TypeScript code
npm run build

# Run all tests
npm test

# Compile the smart contracts
npm run compile

# Test the smart contracts
npm run test:contracts

# Start a local blockchain for testing
npm run node

# Check code quality
npm run lint

# Auto-format your code
npm run format
```

## How the code is organized

```
il-guard-mini/
├── contracts/          # Smart contracts (the blockchain code)
├── src/               # Main application code
├── frontend/          # Web interface for users
├── bot/              # Automated rebalancing system
├── database/         # Data storage setup
├── test/             # All the tests
├── scripts/          # Deployment and helper scripts
└── artifacts/        # Compiled contract files
```

## System overview

The project has four main parts that work together:

1. **Web Interface**: A React app where users can manage their positions
2. **Smart Contracts**: Blockchain contracts that handle the actual position management
3. **Automation Bot**: A background service that monitors prices and triggers rebalancing
4. **Database**: Stores user preferences and historical data

## Contributing

Want to help improve IL Guard Mini? Here's how:

1. Fork this repository to your GitHub account
2. Create a new branch for your feature or fix
3. Make your changes and test them thoroughly
4. Run the linting and formatting tools
5. Submit a pull request with a clear description of what you've changed

## License

This project is open source under the MIT License. See the LICENSE file for the full details.
