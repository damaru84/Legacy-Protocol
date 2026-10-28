const { ethers } = require("hardhat");

async function main() {
  const Factory = await ethers.getContractFactory("LegacyFactory");
  const factory = await Factory.deploy();
  await factory.waitForDeployment();
  console.log("LegacyFactory desplegada en:", await factory.getAddress());
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
