//const { deployProxy } = require('@openzeppelin/truffle-upgrades');
const SAndB = artifacts.require("SheriffAndBandit");
const WEST = artifacts.require("WEST");
const Train = artifacts.require("Train3");
const Random = artifacts.require("Random");
const Traits = artifacts.require("Traits3");

module.exports = async function(deployer, network, accounts) {
  await deployer.deploy(WEST);
  await deployer.deploy(Random);
  await deployer.deploy(Traits);

  const traitsInstance = await Traits.deployed();
  const westInstance = await WEST.deployed();
  const randomInstance = await Random.deployed();

  await westInstance.addController(accounts[0]);
  await westInstance.mint(accounts[0], BigInt(10000e18)); // Mint 10,000 west to owner

  await deployer.deploy(
    SAndB,
    westInstance.address,
    traitsInstance.address,
    "50000"
  ); //50,00 max supply
  const sandbInstance = await SAndB.deployed();

  await traitsInstance.setGame(sandbInstance.address);
  await sandbInstance.setRandomSource(randomInstance.address);
  await randomInstance.setGame(sandbInstance.address);

  await deployer.deploy(Train, sandbInstance.address, westInstance.address);
  const trainInstance = await Train.deployed();

  await sandbInstance.setTrain(trainInstance.address);
  await westInstance.addController(trainInstance.address);
  await trainInstance.setClaiming(true);
};
