# IL Guard Mini

IL Guard Mini is a "Protect my LP" one-tap tool designed to reduce impermanent loss (IL) for liquidity providers on DragonSwap. The system provides automated rebalancing for UniV3 positions based on price movements and volatility triggers.

## Features

- 🛡️ **One-tap Protection**: Simple toggle to enable/disable IL protection
- 📊 **Real-time Dashboard**: Monitor fees earned, estimated IL, and recent actions
- 🤖 **Automated Rebalancing**: Smart rebalancing based on price bands and volatility
- ⚡ **Base Network**: Optimized for Base network with low gas costs
- 🔒 **Emergency Controls**: Pause functionality for immediate manual control

## Quick Start

### Prerequisites

- Node.js 18+ and npm
- Git

### Installation

1. Clone the repository:

```bash
git clone <repository-url>
cd il-guard-mini
```

2. Install dependencies:

```bash
npm install
```

3. Copy environment variables:

```bash
cp .env.example .env
```

4. Configure your `.env` file with appropriate values

### Development

```bash
# Compile TypeScript
npm run build

# Run tests
npm test

# Compile smart contracts
npm run compile

# Run contract tests
npm run test:contracts

# Start local Hardhat network
npm run node

# Lint code
npm run lint

# Format code
npm run format
```

## Project Structure

```
il-guard-mini/
├── contracts/          # Solidity smart contracts
├── src/               # Core TypeScript source code
├── frontend/          # Base Mini App frontend
├── bot/              # Automation bot
├── database/         # Database schemas and migrations
├── test/             # Test files
├── scripts/          # Deployment and utility scripts
└── artifacts/        # Compiled contract artifacts
```

## Architecture

The system consists of four main components:

1. **Base Mini App**: React frontend for user interactions
2. **Smart Contracts**: Solidity contracts for position management
3. **Automation Bot**: TypeScript bot for monitoring and rebalancing
4. **Database**: GolemDB for persistent state management

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests and linting
5. Submit a pull request

## License

MIT License - see LICENSE file for details
