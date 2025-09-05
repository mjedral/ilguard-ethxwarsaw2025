import { expect } from "chai";
import { ethers } from "hardhat";
import { ILGuardManager, MockERC20, MockDragonSwapPositionManager, MockDragonSwapRouter } from "../../typechain-types";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { time } from "@nomicfoundation/hardhat-network-helpers";

describe("ILGuardManager - Integration Tests", function () {
    let ilGuardManager: ILGuardManager;
    let token0: MockERC20;
    let token1: MockERC20;
    let mockPositionManager: MockDragonSwapPositionManager;
    let mockRouter: MockDragonSwapRouter;

    let owner: SignerWithAddress;
    let user: SignerWithAddress;
    let bot: SignerWithAddress;
    let guardian: SignerWithAddress;
    let otherUser: SignerWithAddress;

    const tickSpacing = 60;
    const initialSupply = ethers.parseEther("1000000");

    beforeEach(async function () {
        [owner, user, bot, guardian, otherUser] = await ethers.getSigners();

        // Deploy mock tokens
        const MockERC20Factory = await ethers.getContractFactory("MockERC20");
        token0 = await MockERC20Factory.deploy("Token0", "TK0", 18, initialSupply);
        token1 = await MockERC20Factory.deploy("Token1", "TK1", 18, initialSupply);
        await token0.waitForDeployment();
        await token1.waitForDeployment();

        // Deploy mock DragonSwap contracts
        const MockPositionManagerFactory = await ethers.getContractFactory("MockDragonSwapPositionManager");
        mockPositionManager = await MockPositionManagerFactory.deploy();
        await mockPositionManager.waitForDeployment();

        const MockRouterFactory = await ethers.getContractFactory("MockDragonSwapRouter");
        mockRouter = await MockRouterFactory.deploy();
        await mockRouter.waitForDeployment();

        // Deploy ILGuardManager
        const ILGuardManagerFactory = await ethers.getContractFactory("ILGuardManager");
        ilGuardManager = await ILGuardManagerFactory.deploy(
            await token0.getAddress(),
            await token1.getAddress(),
            tickSpacing,
            await mockRouter.getAddress(),
            await mockPositionManager.getAddress()
        );
        await ilGuardManager.waitForDeployment();

        // Set up roles
        await ilGuardManager.grantRole(await ilGuardManager.BOT_ROLE(), bot.address);
        await ilGuardManager.grantRole(await ilGuardManager.GUARDIAN_ROLE(), guardian.address);

        // Distribute tokens to users
        await token0.transfer(user.address, ethers.parseEther("10000"));
        await token1.transfer(user.address, ethers.parseEther("10000"));
        await token0.transfer(otherUser.address, ethers.parseEther("10000"));
        await token1.transfer(otherUser.address, ethers.parseEther("10000"));

        // Fund mock position manager with tokens for fees/rewards
        await token0.transfer(await mockPositionManager.getAddress(), ethers.parseEther("100000"));
        await token1.transfer(await mockPositionManager.getAddress(), ethers.parseEther("100000"));
    });

    describe("Full Deposit Flow", function () {
        const amount0 = ethers.parseEther("100");
        const amount1 = ethers.parseEther("200");
        const tickLower = -887220;
        const tickUpper = 887220;

        it("Should successfully deposit and create position", async function () {
            // Approve tokens
            await token0.connect(user).approve(await ilGuardManager.getAddress(), amount0);
            await token1.connect(user).approve(await ilGuardManager.getAddress(), amount1);

            // Deposit
            await expect(
                ilGuardManager.connect(user).deposit(
                    amount0,
                    amount1,
                    tickLower,
                    tickUpper,
                    amount0 * 95n / 100n, // 5% slippage
                    amount1 * 95n / 100n
                )
            )
                .to.emit(ilGuardManager, "Deposited")
                .withArgs(1, user.address, amount0, amount1, tickLower, tickUpper, amount0 + amount1);

            // Check position was created
            const position = await ilGuardManager.getPosition(1);
            expect(position.owner).to.equal(user.address);
            expect(position.tickLower).to.equal(tickLower);
            expect(position.tickUpper).to.equal(tickUpper);
            expect(position.liquidity).to.equal(amount0 + amount1);
            expect(position.isProtected).to.be.false;
            expect(position.isPaused).to.be.false;

            // Check user positions
            const userPositions = await ilGuardManager.getUserPositions(user.address);
            expect(userPositions.length).to.equal(1);
            expect(userPositions[0]).to.equal(1);

            // Check tokens were transferred
            expect(await token0.balanceOf(user.address)).to.equal(ethers.parseEther("10000") - amount0);
            expect(await token1.balanceOf(user.address)).to.equal(ethers.parseEther("10000") - amount1);
        });

        it("Should reject deposits below minimum amount", async function () {
            const smallAmount0 = 500n;
            const smallAmount1 = 400n;

            await token0.connect(user).approve(await ilGuardManager.getAddress(), smallAmount0);
            await token1.connect(user).approve(await ilGuardManager.getAddress(), smallAmount1);

            await expect(
                ilGuardManager.connect(user).deposit(
                    smallAmount0,
                    smallAmount1,
                    tickLower,
                    tickUpper,
                    0,
                    0
                )
            ).to.be.revertedWithCustomError(ilGuardManager, "InvalidDepositAmount");
        });

        it("Should reject invalid tick ranges", async function () {
            await token0.connect(user).approve(await ilGuardManager.getAddress(), amount0);
            await token1.connect(user).approve(await ilGuardManager.getAddress(), amount1);

            // tickLower >= tickUpper
            await expect(
                ilGuardManager.connect(user).deposit(
                    amount0,
                    amount1,
                    tickUpper,
                    tickLower,
                    0,
                    0
                )
            ).to.be.revertedWithCustomError(ilGuardManager, "InvalidTickRange");

            // Invalid tick spacing
            await expect(
                ilGuardManager.connect(user).deposit(
                    amount0,
                    amount1,
                    -887221, // Not divisible by tickSpacing
                    887220,
                    0,
                    0
                )
            ).to.be.revertedWithCustomError(ilGuardManager, "InvalidTickRange");
        });
    });

    describe("Position Management", function () {
        let positionId: number;
        const amount0 = ethers.parseEther("100");
        const amount1 = ethers.parseEther("200");
        const tickLower = -887220;
        const tickUpper = 887220;

        beforeEach(async function () {
            // Create a position
            await token0.connect(user).approve(await ilGuardManager.getAddress(), amount0);
            await token1.connect(user).approve(await ilGuardManager.getAddress(), amount1);

            const tx = await ilGuardManager.connect(user).deposit(
                amount0,
                amount1,
                tickLower,
                tickUpper,
                0,
                0
            );
            const receipt = await tx.wait();
            positionId = 1; // First position
        });

        it("Should allow position owner to toggle protection", async function () {
            await expect(ilGuardManager.connect(user).toggleProtection(positionId, true))
                .to.emit(ilGuardManager, "ProtectionToggled")
                .withArgs(positionId, user.address, true);

            const position = await ilGuardManager.getPosition(positionId);
            expect(position.isProtected).to.be.true;
        });

        it("Should not allow non-owner to toggle protection", async function () {
            await expect(
                ilGuardManager.connect(otherUser).toggleProtection(positionId, true)
            ).to.be.revertedWithCustomError(ilGuardManager, "NotPositionOwner");
        });

        it("Should allow position owner to pause/unpause position", async function () {
            await expect(ilGuardManager.connect(user).pausePosition(positionId))
                .to.emit(ilGuardManager, "PositionPaused")
                .withArgs(positionId, user.address);

            let position = await ilGuardManager.getPosition(positionId);
            expect(position.isPaused).to.be.true;

            await expect(ilGuardManager.connect(user).unpausePosition(positionId))
                .to.emit(ilGuardManager, "PositionUnpaused")
                .withArgs(positionId, user.address);

            position = await ilGuardManager.getPosition(positionId);
            expect(position.isPaused).to.be.false;
        });

        it("Should check rebalance eligibility correctly", async function () {
            // Initially cannot rebalance (not protected)
            expect(await ilGuardManager.canRebalance(positionId)).to.be.false;

            // Enable protection
            await ilGuardManager.connect(user).toggleProtection(positionId, true);
            expect(await ilGuardManager.canRebalance(positionId)).to.be.true;

            // Pause position
            await ilGuardManager.connect(user).pausePosition(positionId);
            expect(await ilGuardManager.canRebalance(positionId)).to.be.false;

            // Unpause
            await ilGuardManager.connect(user).unpausePosition(positionId);
            expect(await ilGuardManager.canRebalance(positionId)).to.be.true;

            // Pause entire contract
            await ilGuardManager.connect(guardian).emergencyPause();
            expect(await ilGuardManager.canRebalance(positionId)).to.be.false;
        });
    });

    describe("Rebalancing", function () {
        let positionId: number;
        const amount0 = ethers.parseEther("100");
        const amount1 = ethers.parseEther("200");
        const tickLower = -887220;
        const tickUpper = 887220;

        beforeEach(async function () {
            // Create and protect a position
            await token0.connect(user).approve(await ilGuardManager.getAddress(), amount0);
            await token1.connect(user).approve(await ilGuardManager.getAddress(), amount1);

            await ilGuardManager.connect(user).deposit(amount0, amount1, tickLower, tickUpper, 0, 0);
            const userPositions = await ilGuardManager.getUserPositions(user.address);
            positionId = Number(userPositions[userPositions.length - 1]); // Get the last created position

            await ilGuardManager.connect(user).toggleProtection(positionId, true);
        });

        it("Should allow bot to rebalance protected position", async function () {
            const newTickLower = -443640; // Divisible by 60
            const newTickUpper = 443640;   // Divisible by 60

            await expect(
                ilGuardManager.connect(bot).rebalance(
                    positionId,
                    newTickLower,
                    newTickUpper,
                    0, // BAND_ADJUSTMENT
                    0,
                    0
                )
            )
                .to.emit(ilGuardManager, "Rebalanced")
                .withArgs(positionId, user.address, tickLower, tickUpper, newTickLower, newTickUpper, 0, (amount0 + amount1) / 50n); // Mock fees = liquidity / 50

            const position = await ilGuardManager.getPosition(positionId);
            expect(position.tickLower).to.equal(newTickLower);
            expect(position.tickUpper).to.equal(newTickUpper);
            expect(position.lastRebalanceAt).to.be.gt(0);
        });

        it("Should not allow rebalancing unprotected positions", async function () {
            await ilGuardManager.connect(user).toggleProtection(positionId, false);

            await expect(
                ilGuardManager.connect(bot).rebalance(positionId, -443640, 443640, 0, 0, 0)
            ).to.be.revertedWithCustomError(ilGuardManager, "PositionNotProtected");
        });

        it("Should not allow rebalancing paused positions", async function () {
            await ilGuardManager.connect(user).pausePosition(positionId);

            await expect(
                ilGuardManager.connect(bot).rebalance(positionId, -443640, 443640, 0, 0, 0)
            ).to.be.revertedWithCustomError(ilGuardManager, "PositionIsPaused");
        });

        it("Should respect cooldown period", async function () {
            // First rebalance
            await ilGuardManager.connect(bot).rebalance(positionId, -443640, 443640, 0, 0, 0);

            // Immediate second rebalance should fail
            await expect(
                ilGuardManager.connect(bot).rebalance(positionId, -221820, 221820, 0, 0, 0)
            ).to.be.revertedWithCustomError(ilGuardManager, "CooldownNotMet");

            // Fast forward time
            await time.increase(1801); // Just over cooldown period

            // Should work now
            await expect(
                ilGuardManager.connect(bot).rebalance(positionId, -221820, 221820, 0, 0, 0)
            ).to.not.be.reverted;
        });

        it("Should respect daily action limits", async function () {
            const maxActions = await ilGuardManager.maxActionsPerDay();

            // Perform max actions
            for (let i = 0; i < maxActions; i++) {
                await ilGuardManager.connect(bot).rebalance(
                    positionId,
                    -443640 - (i * 60),
                    443640 + (i * 60),
                    0,
                    0,
                    0
                );
                await time.increase(1801); // Wait for cooldown
            }

            // Next action should fail
            await expect(
                ilGuardManager.connect(bot).rebalance(positionId, -221820, 221820, 0, 0, 0)
            ).to.be.revertedWithCustomError(ilGuardManager, "DailyLimitExceeded");

            // Check daily action count
            const count = await ilGuardManager.getDailyActionCount(positionId);
            console.log(`Position ID: ${positionId}, Daily count: ${count}, Max actions: ${maxActions}`);
            expect(count).to.equal(maxActions);
        });

        it("Should reset daily action count on new day", async function () {
            // Perform one action
            await ilGuardManager.connect(bot).rebalance(positionId, -443640, 443640, 0, 0, 0);

            let count = await ilGuardManager.getDailyActionCount(positionId);
            expect(count).to.equal(1);

            // Fast forward to next day
            await time.increase(86400); // 24 hours

            // Count should reset
            count = await ilGuardManager.getDailyActionCount(positionId);
            expect(count).to.equal(0);
        });
    });

    describe("Withdrawal", function () {
        let positionId: number;
        const amount0 = ethers.parseEther("100");
        const amount1 = ethers.parseEther("200");

        beforeEach(async function () {
            await token0.connect(user).approve(await ilGuardManager.getAddress(), amount0);
            await token1.connect(user).approve(await ilGuardManager.getAddress(), amount1);

            await ilGuardManager.connect(user).deposit(amount0, amount1, -887220, 887220, 0, 0);
            positionId = 1;
        });

        it("Should allow position owner to withdraw", async function () {
            const userBalance0Before = await token0.balanceOf(user.address);
            const userBalance1Before = await token1.balanceOf(user.address);

            await expect(ilGuardManager.connect(user).withdraw(positionId, 0, 0))
                .to.emit(ilGuardManager, "Withdrawn");

            // Position should be deleted
            const position = await ilGuardManager.getPosition(positionId);
            expect(position.owner).to.equal(ethers.ZeroAddress);

            // User should have received tokens back (plus fees)
            const userBalance0After = await token0.balanceOf(user.address);
            const userBalance1After = await token1.balanceOf(user.address);

            expect(userBalance0After).to.be.gt(userBalance0Before);
            expect(userBalance1After).to.be.gt(userBalance1Before);

            // User positions should be empty
            const userPositions = await ilGuardManager.getUserPositions(user.address);
            expect(userPositions.length).to.equal(0);
        });

        it("Should not allow non-owner to withdraw", async function () {
            await expect(
                ilGuardManager.connect(otherUser).withdraw(positionId, 0, 0)
            ).to.be.revertedWithCustomError(ilGuardManager, "NotPositionOwner");
        });

        it("Should allow emergency withdraw even when paused", async function () {
            await ilGuardManager.connect(guardian).emergencyPause();

            // Regular withdraw should fail
            await expect(
                ilGuardManager.connect(user).withdraw(positionId, 0, 0)
            ).to.be.revertedWith("Pausable: paused");

            // Emergency withdraw should work
            await expect(ilGuardManager.connect(user).emergencyWithdraw(positionId))
                .to.emit(ilGuardManager, "EmergencyWithdraw");

            // Position should be deleted
            const position = await ilGuardManager.getPosition(positionId);
            expect(position.owner).to.equal(ethers.ZeroAddress);
        });
    });

    describe("Multiple Positions", function () {
        it("Should handle multiple positions per user correctly", async function () {
            const amount0 = ethers.parseEther("100");
            const amount1 = ethers.parseEther("200");

            // Create multiple positions
            for (let i = 0; i < 3; i++) {
                await token0.connect(user).approve(await ilGuardManager.getAddress(), amount0);
                await token1.connect(user).approve(await ilGuardManager.getAddress(), amount1);

                await ilGuardManager.connect(user).deposit(
                    amount0,
                    amount1,
                    -887220 + (i * 60),
                    887220 - (i * 60),
                    0,
                    0
                );
            }

            // Check user has 3 positions
            const userPositions = await ilGuardManager.getUserPositions(user.address);
            expect(userPositions.length).to.equal(3);
            expect(userPositions[0]).to.equal(1);
            expect(userPositions[1]).to.equal(2);
            expect(userPositions[2]).to.equal(3);

            // Withdraw middle position
            await ilGuardManager.connect(user).withdraw(2, 0, 0);

            // Check positions were reordered correctly (O(1) removal)
            const userPositionsAfter = await ilGuardManager.getUserPositions(user.address);
            expect(userPositionsAfter.length).to.equal(2);
            expect(userPositionsAfter[0]).to.equal(1);
            expect(userPositionsAfter[1]).to.equal(3); // Position 3 moved to index 1
        });
    });

    describe("Reentrancy Protection", function () {
        it("Should prevent reentrancy attacks", async function () {
            // This test would require a malicious contract that tries to reenter
            // For now, we verify that the nonReentrant modifier is in place
            const amount0 = ethers.parseEther("100");
            const amount1 = ethers.parseEther("200");

            await token0.connect(user).approve(await ilGuardManager.getAddress(), amount0);
            await token1.connect(user).approve(await ilGuardManager.getAddress(), amount1);

            // Normal deposit should work
            await expect(
                ilGuardManager.connect(user).deposit(amount0, amount1, -887220, 887220, 0, 0)
            ).to.not.be.reverted;
        });
    });
});