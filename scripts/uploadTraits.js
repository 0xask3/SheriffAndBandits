const Traits = artifacts.require("Traits3");
module.exports = async (done) => {
  const accounts = await web3.eth.getAccounts();
  const traitsInstance = await Traits.deployed();

  let traitType = String(14);
  let jsonData = require("../res/jsons/" + traitType + ".json");
  console.log("Trait type: " + traitType);
  console.log("Total traits: " + jsonData.length);

  let traitIds = [];
  let traitsArray = [];
  for (i = 0; i < jsonData.length; i++) {
    traitIds.push(i);
    traitsArray.push({
      name: jsonData[i].Name,
      png: jsonData[i].Base64,
    });
    if (i % 5 == 0) {
      await traitsInstance.uploadTraits(
        traitType,
        traitIds,
        traitsArray,
        { from: accounts[0] }
      );
      console.log("Uploading traits: " + traitIds);
      console.log("Traits: " + traitsArray.map((a) => a.name));
      traitIds = [];
      traitsArray = [];
    }
  }

  if (traitIds.length != 0) {
    await traitsInstance.uploadTraits(
      traitType,
      traitIds,
      traitsArray,
      { from: accounts[0] }
    );
    console.log("Uploading traits: " + traitIds);
    console.log("Traits: " + traitsArray.map((a) => a.name));
  }

  console.log("Finished Uploading!!");
  done();
};
