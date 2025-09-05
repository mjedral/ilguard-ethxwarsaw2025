import { expect } from "chai";
import { ethers } from "hardhat";
import { ILGuardManager } from "../../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("ILGuardManager", function () {
    let ilGuardManager: ILGuardManager;
    let owner: SignerWithAddress;
    let user: SignerWithAddress;
    let bot: SignerWithAddress;
    let otherUser: SignerWithAddress;

    beforeEach(async function () {
        [owner, user, bot, otherUser] = await ethers.getSigners();

        const ILGuardManagerFactory = await ethers.getContractFactory("ILGuardManager");
        ilGuardManager = await ILGuardManagerFactory.deploy();
        await ilGuardManager.waitForDeployment();

        // Set bot address
        await ilGuardManager.setBotAddress(bot.address);
    });

    describe("Deployment", function () {
        it("Should set the right owner", async function () {
            expect(await ilGuardManager.owner()).to.equal(owner.address);
        });

        it("Should set default parameters correctly", async function () {
            expect(await ilGuardManager.slippageTolerance()).to.equal(30);
            expect(await ilGuardManager.cooldownPeriod()).to.equal(1800);
            expect(await ilGuardManager.maxActionsPerDay()).to.equal(5);
        });
    });

    describe("Position Management", function () {
        it("Should allow users to deposit and create positions", async function () {
            const amount0 = ethers.parseEther("1");
            const amount1 = ethers.parseEther("2000");
            const tickLower = -887220;
            const tickUpper = 887220;

            await expect(
                ilGuardManager.connect(user).deposit(amount0, amount1, tickLower, tickUpper)
            )
                .to.emit(ilGuardManager, "Deposited")
                .withArgs(1, user.address, amount0, amount1, tickLower, tickUpper, amount0 + amount1);

            const position = await ilGuardManager.getPosition(1);
            expect(position.owner).to.equal(user.address);
            expect(position.tickLower).to.equal(tickLower);
            expect(position.tickUpper).to.equal(tickUpper);
            expect(position.isProtected).to.equal(false);
            expect(position.isPaused).to.equal(false);
        });

        it("Should reject invalid deposit parameters", async function () {
            await expect(
                ilGuardManager.connect(user).deposit(0, 0, -887220, 887220)
            ).to.be.revertedWith("ILGuardManager: invalid deposit amounts");

            await expect(
                ilGuardManager.connect(user).deposit(100, 200, 887220, -887220)
            ).to.be.revertedWith("ILGuardManager: invalid tick range");
        });

        it("Should allow position owners to withdraw", async function () {
            // First deposit
            await ilGuardManager.connect(user).deposit(100, 200, -887220, 887220);

            await expect(ilGuardManager.connect(user).withdraw(1))
                .to.emit(ilGuardManager, "Withdrawn")
                .withArgs(1, user.address, 150, 150, 0);

            // Position should be deleted
            const position = await ilGuardManager.getPosition(1);
            expect(position.owner).to.equal(ethers.ZeroAddress);
        });

        it("Should not allow non-owners to withdraw", async function () {
            await ilGuardManager.connect(user).deposit(100, 200, -887220, 887220);

            await expect(
                ilGuardManager.connect(otherUser).withdraw(1)
            ).to.be.revertedWith("ILGuardManager: not position owner");
        });
    });

    describe("Protection Toggle", function () {
        beforeEach(async function () {
            await ilGuardManager.connect(user).deposit(100, 200, -887220, 887220);
        });

        it("Should allow position owners to toggle protection", async function () {
            await expect(ilGuardManager.connect(user).toggleProtection(1, true))
                .to.emit(ilGuardManager, "ProtectionToggled")
                .withArgs(1, user.address, true);

            const position = await ilGuardManager.getPosition(1);
            expect(position.isProtected).to.equal(true);
        });

        it("Should not allow non-owners to toggle protection", async function () {
            await expect(
                ilGuardManager.connect(otherUser).toggleProtection(1, true)
            ).to.be.revertedWith("ILGuardManager: not position owner");
        });
    });

    describe("Emergency Pause", function () {
        beforeEach(async function () {
            await ilGuardManager.connect(user).deposit(100, 200, -887220, 887220);
        });

        it("Should allow position owners to pause their positions", async function () {
            await expect(ilGuardManager.connect(user).emergencyPausePosition(1))
                .to.emit(ilGuardManager, "PositionPaused")
                .withArgs(1, user.address);

            const position = await ilGuardManager.getPosition(1);
            expect(position.isPaused).to.equal(true);
        });

        it("Should allow position owners to unpause their positions", async function () {
            await ilGuardManager.connect(user).emergencyPausePosition(1);

            await expect(ilGuardManager.connect(user).unpausePosition(1))
                .to.emit(ilGuardManager, "PositionUnpaused")
                .withArgs(1, user.address);

            const position = await ilGuardManager.getPosition(1);
            expect(position.isPaused).to.equal(false);
        });

        it("Should allow owner to pause entire contract", async function () {
            await ilGuardManager.emergencyPause();
            expect(await ilGuardManager.paused()).to.equal(true);

            // Should not allow deposits when paused
            await expect(
                ilGuardManager.connect(user).deposit(100, 200, -887220, 887220)
            ).to.be.revertedWith("Pausable: paused");
        });
    });

    describe("Rebalancing", function () {
        beforeEach(async function () {
            await ilGuardManager.connect(user).deposit(100, 200, -887220, 887220);
            await ilGuardManager.connect(user).toggleProtection(1, true);
        });

        it("Should allow bot to rebalance protected positions", async function () {
            const newTickLower = -443610;
            const newTickUpper = 443610;

            await expect(
                ilGuardManager.connect(bot).rebalance(1, newTickLower, newTickUpper, "band")
            )
                .to.emit(ilGuardManager, "Rebalanced")
                .withArgs(1, user.address, -887220, 887220, newTickLower, newTickUpper, "band", 0);

            const position = await ilGuardManager.getPosition(1);
            expect(position.tickLower).to.equal(newTickLower);
            expect(position.tickUpper).to.equal(newTickUpper);
        });

        it("Should not allow rebalancing unprotected positions", async function () {
            await ilGuardManager.connect(user).toggleProtection(1, false);

            await expect(
                ilGuardManager.connect(bot).rebalance(1, -443610, 443610, "band")
            ).to.be.revertedWith("ILGuardManager: position not protected");
        });

        it("Should not allow rebalancing paused positions", async function () {
            await ilGuardManager.connect(user).emergencyPausePosition(1);

            await expect(
                ilGuardManager.connect(bot).rebalance(1, -443610, 443610, "band")
            ).to.be.revertedWith("ILGuardManager: position is paused");
        });

        it("Should not allow non-bot to rebalance", async function () {
            await expect(
                ilGuardManager.connect(user).rebalance(1, -443610, 443610, "band")
            ).to.be.revertedWith("ILGuardManager: caller is not the bot");
        });
    });

    describe("Access Control", function () {
        it("Should allow owner to set bot address", async function () {
            const newBot = otherUser.address;

            await expect(ilGuardManager.setBotAddress(newBot))
                .to.emit(ilGuardManager, "BotAddressUpdated")
                .withArgs(bot.address, newBot);

            expect(await ilGuardManager.botAddress()).to.equal(newBot);
        });

        it("Should not allow non-owner to set bot address", async function () {
            await expect(
                ilGuardManager.connect(user).setBotAddress(otherUser.address)
            ).to.be.revertedWith("Ownable: caller is not the owner");
        });

        it("Should allow owner to set slippage tolerance", async function () {
            const newTolerance = 50;

            await expect(ilGuardManager.setSlippageTolerance(newTolerance))
                .to.emit(ilGuardManager, "SlippageToleranceUpdated")
                .withArgs(30, newTolerance);

            expect(await ilGuardManager.slippageTolerance()).to.equal(newTolerance);
        });

        it("Should reject invalid slippage tolerance", async function () {
            await expect(
                ilGuardManager.setSlippageTolerance(1001)
            ).to.be.revertedWith("ILGuardManager: tolerance too high");
        });
    });

    describe("View Functions", function () {
        beforeEach(async function () {
            await ilGuardManager.connect(user).deposit(100, 200, -887220, 887220);
            await ilGuardManager.connect(user).deposit(150, 250, -443610, 443610);
        });

        it("Should return user positions", async function () {
            const userPositions = await ilGuardManager.getUserPositions(user.address);
            expect(userPositions.length).to.equal(2);
            expect(userPositions[0]).to.equal(1);
            expect(userPositions[1]).to.equal(2);
        });

        it("Should check if position can be rebalanced", async function () {
            // Initially cannot rebalance (not protected)
            expect(await ilGuardManager.canRebalance(1)).to.equal(false);

            // Enable protection
            await ilGuardManager.connect(user).toggleProtection(1, true);
            expect(await ilGuardManager.canRebalance(1)).to.equal(true);

            // Pause position
            await ilGuardManager.connect(user).emergencyPausePosition(1);
            expect(await ilGuardManager.canRebalance(1)).to.equal(false);
        });
    });
});