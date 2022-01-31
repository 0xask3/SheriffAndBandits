const Traits = artifacts.require("Traits3");
const fs = require("fs");

module.exports = async (done) => {
  const accounts = await web3.eth.getAccounts();
  const traitsInstance = await Traits.deployed();
  const dir = fs.readdirSync("./res/jsons/");
  console.log("Traits Contract: " + traitsInstance.address + "\n");
  const traitType = [...Array(dir.length).keys()];
  let traitCount = [];

  for (j = 0; j < dir.length; j++) {
    let traitType = String(j);
    let jsonData = require("../res/jsons/" + traitType + ".json");
        console.log("Trait type                : " + traitType);
        console.log("Total traits              : " + jsonData.length);

    let traitIds = [];
    let traitsArray = [];
    traitCount.push(jsonData.length);

    for (i = 0; i < jsonData.length; i++) {
      traitIds.push(i);
      traitsArray.push({
        name: jsonData[i].Name,
        png: jsonData[i].Base64,
      });
      if (i % 5 == 0) {
        await traitsInstance.uploadTraits(traitType, traitIds, traitsArray, {
          from: accounts[0],
        });
        console.log("Uploading traits          : " + traitIds);
        console.log("Traits                    : " + traitsArray.map((a) => a.name));
        traitIds = [];
        traitsArray = [];
      }
    }

    if (traitIds.length != 0) {
      await traitsInstance.uploadTraits(traitType, traitIds, traitsArray, {
        from: accounts[0],
      });
        console.log("Uploading traits          : " + traitIds);
        console.log("Traits                    : " + traitsArray.map((a) => a.name));
    }

        console.log("Finished uploading trait  : " + j + "\n");
  }

  console.log("Finished uploading traits!!");
  console.log("Setting traits count...");
  await traitsInstance.setTraitCountForType(traitType, traitCount);
  console.log("Finished uploading trait counts! \n");

  console.log("Uploading Bodies...");
  const banditBody = fs.readFileSync("./res/BanditBody/bandit.txt");
  const sheriffBody = fs.readFileSync("./res/SheriffBody/sheriff.txt");
  await traitsInstance.uploadBodies(String(sheriffBody), String(banditBody));
  console.log("Bodies added succesfully");
  console.log("Finished Execution!!");
  done();
};
