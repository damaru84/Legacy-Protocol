const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time, loadFixture } = require("@nomicfoundation/hardhat-network-helpers");

const DAY = 24 * 60 * 60;
const ETH = ethers.ZeroAddress;
const State = { Active: 0, UnderReview: 1, InChallenge: 2, ClaimsEnabled: 3, Finalized: 4 };

async function deployFixture() {
  const [owner, g1, g2, g3, alice, bob, stranger] = await ethers.getSigners();

  const Vault = await ethers.getContractFactory("LegacyVault");
  const vault = await Vault.deploy(
    owner.address,
    30 * DAY,
    7 * DAY,
    [g1.address, g2.address, g3.address],
    2
  );

  const Token = await ethers.getContractFactory("MockERC20");
  const usdc = await Token.deploy("Mock USDC", "mUSDC");
  await usdc.mint(owner.address, 1_000n * 10n ** 6n);

  return { vault, usdc, owner, g1, g2, g3, alice, bob, stranger };
}

// Plan del whitepaper: 10 ETH (60/40) y 1.000 USDC (20/80)
async function fundedFixture() {
  const ctx = await deployFixture();
  const { vault, usdc, owner, alice, bob } = ctx;

  await vault.setAllocation(ETH, [
    { beneficiary: alice.address, bps: 6000 },
    { beneficiary: bob.address, bps: 4000 },
  ]);
  await vault.setAllocation(await usdc.getAddress(), [
    { beneficiary: alice.address, bps: 2000 },
    { beneficiary: bob.address, bps: 8000 },
  ]);

  await owner.sendTransaction({ to: await vault.getAddress(), value: ethers.parseEther("10") });
  await usdc.approve(await vault.getAddress(), 1_000n * 10n ** 6n);
  await vault.depositToken(await usdc.getAddress(), 1_000n * 10n ** 6n);

  return ctx;
}

async function toClaimsEnabled(ctx) {
  const { vault, g1, g2 } = ctx;
  await time.increase(30 * DAY + 1);
  await vault.startReview();
  await vault.connect(g1).approveActivation();
  await vault.connect(g2).approveActivation();
  await time.increase(7 * DAY + 1);
  await vault.enableClaims();
}

describe("LegacyVault", () => {
  describe("configuración", () => {
    it("rechaza porcentajes que no suman 100 %", async () => {
      const { vault, alice, bob } = await loadFixture(deployFixture);
      await expect(
        vault.setAllocation(ETH, [
          { beneficiary: alice.address, bps: 5000 },
          { beneficiary: bob.address, bps: 4000 },
        ])
      ).to.be.revertedWithCustomError(vault, "BadTotal");
    });

    it("rechaza beneficiarios duplicados y direcciones cero", async () => {
      const { vault, alice } = await loadFixture(deployFixture);
      await expect(
        vault.setAllocation(ETH, [
          { beneficiary: alice.address, bps: 5000 },
          { beneficiary: alice.address, bps: 5000 },
        ])
      ).to.be.revertedWithCustomError(vault, "DuplicateBeneficiary");
      await expect(
        vault.setAllocation(ETH, [{ beneficiary: ethers.ZeroAddress, bps: 10000 }])
      ).to.be.revertedWithCustomError(vault, "InvalidShare");
    });

    it("solo el titular configura", async () => {
      const { vault, stranger, alice } = await loadFixture(deployFixture);
      await expect(
        vault.connect(stranger).setAllocation(ETH, [{ beneficiary: alice.address, bps: 10000 }])
      ).to.be.revertedWithCustomError(vault, "NotOwner");
    });

    it("un arreglo vacío elimina el activo", async () => {
      const { vault, alice } = await loadFixture(deployFixture);
      await vault.setAllocation(ETH, [{ beneficiary: alice.address, bps: 10000 }]);
      expect(await vault.getAssets()).to.deep.equal([ETH]);
      await vault.setAllocation(ETH, []);
      expect(await vault.getAssets()).to.deep.equal([]);
    });
  });

  describe("activación", () => {
    it("no permite iniciar revisión antes del plazo de inactividad", async () => {
      const { vault } = await loadFixture(fundedFixture);
      await expect(vault.startReview()).to.be.revertedWithCustomError(vault, "NotInactiveYet");
    });

    it("no permite iniciar revisión con un plan vacío", async () => {
      const { vault } = await loadFixture(deployFixture);
      await time.increase(30 * DAY + 1);
      await expect(vault.startReview()).to.be.revertedWithCustomError(vault, "EmptyPlan");
    });

    it("ping reinicia el contador de inactividad", async () => {
      const { vault } = await loadFixture(fundedFixture);
      await time.increase(25 * DAY);
      await vault.ping();
      await time.increase(25 * DAY);
      await expect(vault.startReview()).to.be.revertedWithCustomError(vault, "NotInactiveYet");
    });

    it("solo guardianes aprueban y no pueden votar dos veces", async () => {
      const { vault, g1, stranger } = await loadFixture(fundedFixture);
      await time.increase(30 * DAY + 1);
      await vault.startReview();
      await expect(vault.connect(stranger).approveActivation()).to.be.revertedWithCustomError(
        vault,
        "NotGuardian"
      );
      await vault.connect(g1).approveActivation();
      await expect(vault.connect(g1).approveActivation()).to.be.revertedWithCustomError(
        vault,
        "AlreadyApproved"
      );
    });

    it("alcanzado el umbral pasa a impugnación y no habilita reclamos antes de tiempo", async () => {
      const { vault, g1, g2 } = await loadFixture(fundedFixture);
      await time.increase(30 * DAY + 1);
      await vault.startReview();
      await vault.connect(g1).approveActivation();
      expect(await vault.state()).to.equal(State.UnderReview);
      await vault.connect(g2).approveActivation();
      expect(await vault.state()).to.equal(State.InChallenge);
      await expect(vault.enableClaims()).to.be.revertedWithCustomError(vault, "ChallengeNotOver");
    });

    it("el titular puede abortar el proceso durante la impugnación", async () => {
      const { vault, g1, g2 } = await loadFixture(fundedFixture);
      await time.increase(30 * DAY + 1);
      await vault.startReview();
      await vault.connect(g1).approveActivation();
      await vault.connect(g2).approveActivation();

      await vault.ping();
      expect(await vault.state()).to.equal(State.Active);

      await time.increase(7 * DAY + 1);
      await expect(vault.enableClaims()).to.be.revertedWithCustomError(vault, "WrongState");
    });

    it("el titular no puede retirar fondos una vez iniciada la revisión", async () => {
      const { vault, owner } = await loadFixture(fundedFixture);
      await time.increase(30 * DAY + 1);
      await vault.startReview();
      await expect(
        vault.withdrawETH(owner.address, 1n)
      ).to.be.revertedWithCustomError(vault, "WrongState");
    });
  });

  describe("reclamaciones", () => {
    it("distribuye 10 ETH y 1.000 USDC según los porcentajes por activo", async () => {
      const ctx = await loadFixture(fundedFixture);
      const { vault, usdc, alice, bob } = ctx;
      await toClaimsEnabled(ctx);

      const usdcAddr = await usdc.getAddress();
      await expect(vault.connect(alice).claim(ETH)).to.changeEtherBalance(
        alice,
        ethers.parseEther("6")
      );
      await expect(vault.connect(bob).claim(ETH)).to.changeEtherBalance(
        bob,
        ethers.parseEther("4")
      );
      await expect(vault.connect(alice).claim(usdcAddr)).to.changeTokenBalance(
        usdc,
        alice,
        200n * 10n ** 6n
      );
      await vault.connect(bob).claim(usdcAddr);
      expect(await usdc.balanceOf(bob.address)).to.equal(800n * 10n ** 6n);
      expect(await vault.state()).to.equal(State.Finalized);
    });

    it("impide reclamar dos veces", async () => {
      const ctx = await loadFixture(fundedFixture);
      const { vault, alice } = ctx;
      await toClaimsEnabled(ctx);
      await vault.connect(alice).claim(ETH);
      await expect(vault.connect(alice).claim(ETH)).to.be.revertedWithCustomError(
        vault,
        "AlreadyClaimed"
      );
    });

    it("rechaza a quien no es beneficiario", async () => {
      const ctx = await loadFixture(fundedFixture);
      const { vault, stranger } = ctx;
      await toClaimsEnabled(ctx);
      await expect(vault.connect(stranger).claim(ETH)).to.be.revertedWithCustomError(
        vault,
        "NotBeneficiary"
      );
    });

    it("la parte no reclamada queda pendiente sin redistribuirse", async () => {
      const ctx = await loadFixture(fundedFixture);
      const { vault, alice } = ctx;
      await toClaimsEnabled(ctx);
      await vault.connect(alice).claim(ETH);
      expect(await ethers.provider.getBalance(await vault.getAddress())).to.equal(
        ethers.parseEther("4")
      );
      expect(await vault.state()).to.equal(State.ClaimsEnabled);
    });

    it("claimableOf informa el monto correcto", async () => {
      const ctx = await loadFixture(fundedFixture);
      const { vault, alice } = ctx;
      expect(await vault.claimableOf(ETH, alice.address)).to.equal(0n);
      await toClaimsEnabled(ctx);
      expect(await vault.claimableOf(ETH, alice.address)).to.equal(ethers.parseEther("6"));
    });
  });
});
