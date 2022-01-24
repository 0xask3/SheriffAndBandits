// SPDX-License-Identifier: MIT LICENSE

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC721Receiver.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "./ISheriffAndBandit.sol";
import "./SheriffAndBandit.sol";
import "./WEST.sol";
import "./ITrain.sol";

contract Train3 is Ownable, IERC721Receiver, Pausable {
    // maximum alpha score for a Sheriff
    uint8 public constant MAX_ALPHA = 8;

    // struct to store a stake's token, owner, and earning values
    struct Stake {
        uint16 tokenId;
        uint80 value;
        address owner;
    }

    event TokenStaked(address owner, uint256 tokenId, uint256 value);
    event BanditClaimed(uint256 tokenId, uint256 earned, bool unstaked);
    event SheriffClaimed(uint256 tokenId, uint256 earned, bool unstaked);

    // reference to the SheriffAndBandit NFT contract
    SheriffAndBandit game;
    // reference to the $WEST contract for minting $WEST earnings
    WEST west;

    // maps tokenId to stake
    mapping(uint256 => Stake) public train;
    // maps alpha to all Sheriff stakes with that alpha
    mapping(uint256 => Stake[]) public pack;
    // tracks location of each Sheriff in Pack
    mapping(uint256 => uint256) public packIndices;
    // total alpha scores staked
    uint256 public totalAlphaStaked = 0;
    // any rewards distributed when no sheriff are staked
    uint256 public unaccountedRewards = 0;
    // amount of $WEST due for each alpha point staked
    uint256 public westPerAlpha = 0;

    // bandit earn 10000 $WEST per day
    uint256 public DAILY_WEST_RATE = 10000 ether;
    // bandit must have 2 days worth of $WEST to unstake or else it's too cold
    uint256 public MINIMUM_TO_EXIT = 2 days;
    // sheriffs take a 20% tax on all $WEST claimed
    uint256 public constant WEST_CLAIM_TAX_PERCENTAGE = 20;
    // there will only ever be (roughly) 2.4 billion $WEST earned through staking
    uint256 public constant MAXIMUM_GLOBAL_WEST = 2400000000 ether;

    uint256 public whitelist_start_time = 0;
    uint256 public public_start_time = 0;

    // amount of $WEST earned so far
    uint256 public totalWestEarned;
    // number of Bandit staked in the Train
    uint256 public totalBanditStaked;
    // the last time $WEST was claimed
    uint256 public lastClaimTimestamp;

    // emergency rescue to allow unstaking without any checks but without $WEST
    bool public rescueEnabled = false;

    bool private _reentrant = false;
    bool public canClaim = false;

    modifier nonReentrant() {
        require(!_reentrant, "No reentrancy");
        _reentrant = true;
        _;
        _reentrant = false;
    }

    uint256 oldLastClaimTimestamp;

    /**
     * @param _game reference to the SheriffAndBandit NFT contract
     * @param _west reference to the $WEST token
     */
    constructor(SheriffAndBandit _game, WEST _west) {
        game = _game;
        west = _west;
    }

    function setOldTrainStats(
        uint256 _lastClaimTimestamp,
        uint256 _totalWestEarned
    ) public onlyOwner {
        lastClaimTimestamp = _lastClaimTimestamp;
        totalWestEarned = _totalWestEarned;
    }

    /***STAKING */

    /**
     * adds Bandit and Sheriffs to the Train and Pack
     * @param account the address of the staker
     * @param tokenIds the IDs of the Bandit and Sheriffs to stake
     */
    function addManyToTrainAndPack(address account, uint16[] calldata tokenIds)
        external
        whenNotPaused
        nonReentrant
    {
        require(
            (account == _msgSender() && account == tx.origin) ||
                _msgSender() == address(game),
            "DONT GIVE YOUR TOKENS AWAY"
        );

        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (tokenIds[i] == 0) {
                continue;
            }

            if (_msgSender() != address(game)) {
                // dont do this step if its a mint + stake
                require(
                    game.ownerOf(tokenIds[i]) == _msgSender(),
                    "AINT YO TOKEN"
                );
                game.transferFrom(_msgSender(), address(this), tokenIds[i]);
            }

            if (isBandit(tokenIds[i])) _addBanditToTrain(account, tokenIds[i]);
            else _addSheriffToPack(account, tokenIds[i]);
        }
    }

    /**
     * adds a single Bandit to the Train
     * @param account the address of the staker
     * @param tokenId the ID of the Bandit to add to the Train
     */
    function _addBanditToTrain(address account, uint256 tokenId)
        internal
        whenNotPaused
        _updateEarnings
    {
        train[tokenId] = Stake({
            owner: account,
            tokenId: uint16(tokenId),
            value: uint80(block.timestamp)
        });
        totalBanditStaked += 1;
        emit TokenStaked(account, tokenId, block.timestamp);
    }

    function _addBanditToTrainWithTime(
        address account,
        uint256 tokenId,
        uint256 time
    ) internal {
        totalWestEarned +=
            ((time - lastClaimTimestamp) *
                totalBanditStaked *
                DAILY_WEST_RATE) /
            1 days;

        train[tokenId] = Stake({
            owner: account,
            tokenId: uint16(tokenId),
            value: uint80(time)
        });
        totalBanditStaked += 1;
        emit TokenStaked(account, tokenId, time);
    }

    /**
     * adds a single Sheriff to the Pack
     * @param account the address of the staker
     * @param tokenId the ID of the Sheriff to add to the Pack
     */
    function _addSheriffToPack(address account, uint256 tokenId) internal {
        uint256 alpha = _alphaForSheriff(tokenId);
        totalAlphaStaked += alpha;
        // Portion of earnings ranges from 8 to 5
        packIndices[tokenId] = pack[alpha].length;

        // Store the location of the sheriff in the Pack
        pack[alpha].push(
            Stake({
                owner: account,
                tokenId: uint16(tokenId),
                value: uint80(westPerAlpha)
            })
        );
        // Add the sheriff to the Pack
        emit TokenStaked(account, tokenId, westPerAlpha);
    }

    /***CLAIMING / UNSTAKING */

    /**
     * realize $WEST earnings and optionally unstake tokens from the Train / Pack
     * to unstake a Bandit it will require it has 2 days worth of $WEST unclaimed
     * @param tokenIds the IDs of the tokens to claim earnings from
     * @param unstake whether or not to unstake ALL of the tokens listed in tokenIds
     */
    function claimManyFromTrainAndPack(uint16[] calldata tokenIds, bool unstake)
        external
        nonReentrant
        _updateEarnings
    {
        require(msg.sender == tx.origin, "Only EOA");
        require(canClaim, "Claim deactive");

        uint256 owed = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (isBandit(tokenIds[i]))
                owed += _claimBanditFromTrain(tokenIds[i], unstake);
            else owed += _claimSheriffFromPack(tokenIds[i], unstake);
        }
        if (owed == 0) return;
        west.mint(_msgSender(), owed);
    }

    /**
     * realize $WEST earnings for a single Bandit and optionally unstake it
     * if not unstaking, pay a 20% tax to the staked Sheriffs
     * if unstaking, there is a 50% chance all $WEST is stolen
     * @param tokenId the ID of the Bandit to claim earnings from
     * @param unstake whether or not to unstake the Bandit
     * @return owed - the amount of $WEST earned
     */
    function _claimBanditFromTrain(uint256 tokenId, bool unstake)
        internal
        returns (uint256 owed)
    {
        Stake memory stake = train[tokenId];
        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
        require(
            !(unstake && block.timestamp - stake.value < MINIMUM_TO_EXIT),
            "GONNA BE COLD WITHOUT TWO DAY'S WEST"
        );
        if (totalWestEarned < MAXIMUM_GLOBAL_WEST) {
            owed = ((block.timestamp - stake.value) * DAILY_WEST_RATE) / 1 days;
        } else if (stake.value > lastClaimTimestamp) {
            owed = 0;
            // $WEST production stopped already
        } else {
            owed =
                ((lastClaimTimestamp - stake.value) * DAILY_WEST_RATE) /
                1 days;
            // stop earning additional $WEST if it's all been earned
        }
        if (unstake) {
            if (random(tokenId) & 1 == 1) {
                // 50% chance of all $WEST stolen
                _paySheriffTax(owed);
                owed = 0;
            }
            game.transferFrom(address(this), _msgSender(), tokenId);
            // send back Bandit
            delete train[tokenId];
            totalBanditStaked -= 1;
        } else {
            _paySheriffTax((owed * WEST_CLAIM_TAX_PERCENTAGE) / 100);
            // percentage tax to staked wolves
            owed = (owed * (100 - WEST_CLAIM_TAX_PERCENTAGE)) / 100;
            // remainder goes to Bandit owner
            train[tokenId] = Stake({
                owner: _msgSender(),
                tokenId: uint16(tokenId),
                value: uint80(block.timestamp)
            });
            // reset stake
        }
        emit BanditClaimed(tokenId, owed, unstake);
    }

    /**
     * realize $WEST earnings for a single Sheriff and optionally unstake it
     * Sheriffs earn $WEST proportional to their Alpha rank
     * @param tokenId the ID of the Sheriff to claim earnings from
     * @param unstake whether or not to unstake the Sheriff
     * @return owed - the amount of $WEST earned
     */
    function _claimSheriffFromPack(uint256 tokenId, bool unstake)
        internal
        returns (uint256 owed)
    {
        require(
            game.ownerOf(tokenId) == address(this),
            "AINT A PART OF THE PACK"
        );
        uint256 alpha = _alphaForSheriff(tokenId);
        Stake memory stake = pack[alpha][packIndices[tokenId]];
        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
        owed = (alpha) * (westPerAlpha - stake.value);
        // Calculate portion of tokens based on Alpha
        if (unstake) {
            totalAlphaStaked -= alpha;
            // Remove Alpha from total staked
            game.transferFrom(address(this), _msgSender(), tokenId);
            // Send back Sheriff
            Stake memory lastStake = pack[alpha][pack[alpha].length - 1];
            pack[alpha][packIndices[tokenId]] = lastStake;
            // Shuffle last Sheriff to current position
            packIndices[lastStake.tokenId] = packIndices[tokenId];
            pack[alpha].pop();
            // Remove duplicate
            delete packIndices[tokenId];
            // Delete old mapping
        } else {
            pack[alpha][packIndices[tokenId]] = Stake({
                owner: _msgSender(),
                tokenId: uint16(tokenId),
                value: uint80(westPerAlpha)
            });
            // reset stake
        }
        emit SheriffClaimed(tokenId, owed, unstake);
    }

    /**
     * emergency unstake tokens
     * @param tokenIds the IDs of the tokens to claim earnings from
     */
    function rescue(uint256[] calldata tokenIds) external nonReentrant {
        require(rescueEnabled, "RESCUE DISABLED");
        uint256 tokenId;
        Stake memory stake;
        Stake memory lastStake;
        uint256 alpha;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            tokenId = tokenIds[i];
            if (isBandit(tokenId)) {
                stake = train[tokenId];
                require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
                game.transferFrom(address(this), _msgSender(), tokenId);
                // send back Bandit
                delete train[tokenId];
                totalBanditStaked -= 1;
                emit BanditClaimed(tokenId, 0, true);
            } else {
                alpha = _alphaForSheriff(tokenId);
                stake = pack[alpha][packIndices[tokenId]];
                require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");
                totalAlphaStaked -= alpha;
                // Remove Alpha from total staked
                game.transferFrom(address(this), _msgSender(), tokenId);
                // Send back Sheriff
                lastStake = pack[alpha][pack[alpha].length - 1];
                pack[alpha][packIndices[tokenId]] = lastStake;
                // Shuffle last Sheriff to current position
                packIndices[lastStake.tokenId] = packIndices[tokenId];
                pack[alpha].pop();
                // Remove duplicate
                delete packIndices[tokenId];
                // Delete old mapping
                emit SheriffClaimed(tokenId, 0, true);
            }
        }
    }

    /***ACCOUNTING */

    /**
     * add $WEST to claimable pot for the Pack
     * @param amount $WEST to add to the pot
     */
    function _paySheriffTax(uint256 amount) internal {
        if (totalAlphaStaked == 0) {
            // if there's no staked wolves
            unaccountedRewards += amount;
            // keep track of $WEST due to wolves
            return;
        }
        // makes sure to include any unaccounted $WEST
        westPerAlpha += (amount + unaccountedRewards) / totalAlphaStaked;
        unaccountedRewards = 0;
    }

    /**
     * tracks $WEST earnings to ensure it stops once 2.4 billion is eclipsed
     */
    modifier _updateEarnings() {
        if (totalWestEarned < MAXIMUM_GLOBAL_WEST) {
            totalWestEarned +=
                ((block.timestamp - lastClaimTimestamp) *
                    totalBanditStaked *
                    DAILY_WEST_RATE) /
                1 days;
            lastClaimTimestamp = block.timestamp;
        }
        _;
    }

    /***ADMIN */

    function setSettings(uint256 rate, uint256 exit) external onlyOwner {
        MINIMUM_TO_EXIT = exit;
        DAILY_WEST_RATE = rate;
    }

    /**
     * allows owner to enable "rescue mode"
     * simplifies accounting, prioritizes tokens out in emergency
     */
    function setRescueEnabled(bool _enabled) external onlyOwner {
        rescueEnabled = _enabled;
    }

    /**
     * enables owner to pause / unpause minting
     */
    function setPaused(bool _paused) external onlyOwner {
        if (_paused) _pause();
        else _unpause();
    }

    /***READ ONLY */

    /**
     * checks if a token is a Bandit
     * @param tokenId the ID of the token to check
     * @return bandit - whether or not a token is a Bandit
     */
    function isBandit(uint256 tokenId) public view returns (bool bandit) {
        (bandit, , , , , ) = game.tokenTraits(tokenId);
    }

    /**
     * gets the alpha score for a Sheriff
     * @param tokenId the ID of the Sheriff to get the alpha score for
     * @return the alpha score of the Sheriff (5-8)
     */
    function _alphaForSheriff(uint256 tokenId) internal view returns (uint8) {
        (, ISheriffAndBandit.Sheriff memory s, ) = game.getTokenTraits(tokenId);
        uint8 alphaIndex = s.alphaIndex;
        return MAX_ALPHA - alphaIndex;
        // alpha index is 0-3
    }

    /**
     * chooses a random Sheriff bandit when a newly minted token is stolen
     * @param seed a random value to choose a Sheriff from
     * @return the owner of the randomly selected Sheriff bandit
     */
    function randomSheriffOwner(uint256 seed) external view returns (address) {
        if (totalAlphaStaked == 0) return address(0x0);
        uint256 bucket = (seed & 0xFFFFFFFF) % totalAlphaStaked;
        // choose a value from 0 to total alpha staked
        uint256 cumulative;
        seed >>= 32;
        // loop through each bucket of Sheriffs with the same alpha score
        for (uint256 i = MAX_ALPHA - 3; i <= MAX_ALPHA; i++) {
            cumulative += pack[i].length * i;
            // if the value is not inside of that bucket, keep going
            if (bucket >= cumulative) continue;
            // get the address of a random Sheriff with that alpha score
            return pack[i][seed % pack[i].length].owner;
        }
        return address(0x0);
    }

    /**
     * generates a pseudorandom number
     * @param seed a value ensure different outcomes for different sources in the same block
     * @return a pseudorandom value
     */
    function random(uint256 seed) internal view returns (uint256) {
        return
            uint256(
                keccak256(
                    abi.encodePacked(
                        tx.origin,
                        blockhash(block.number - 1),
                        block.timestamp,
                        seed,
                        totalBanditStaked,
                        totalAlphaStaked,
                        lastClaimTimestamp
                    )
                )
            ) ^ game.randomSource().seed();
    }

    function onERC721Received(
        address,
        address from,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        require(from == address(0x0), "Cannot send tokens to Barn directly");
        return IERC721Receiver.onERC721Received.selector;
    }

    function setGame(SheriffAndBandit _nGame) public onlyOwner {
        game = _nGame;
    }

    function setClaiming(bool _canClaim) public onlyOwner {
        canClaim = _canClaim;
    }
}
