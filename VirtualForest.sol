// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/ChainlinkClient.sol";
import "./ZuraToken.sol";

contract Zuraforest is ERC721, Ownable, ChainlinkClient {
    uint256 public seedId;
    uint256 public timeToGetSeed;

    enum Stages {
        seed,
        sapling,
        tree
    }

    ZuraToken public zuraToken;

    mapping(uint256 => address) public seedToAddress;
    mapping(address => uint256) public addressToGetSeedTime;
    mapping(address => mapping(uint256 => bool)) public wateredSeed;
    mapping(uint256 => uint256) public trackWatering;
    mapping(uint256 => uint256) public seedOriginTime;
    mapping(uint256 => Stages) public seedStages;
    mapping(uint256 => uint256) public fullyGrowthTimeOfSeed;
    mapping(address => address) public approvedAddresses;
    mapping(uint256 => bool) public seedIsLive;
    mapping(uint256 => GeoLocation) public seedCoordinates;

    struct GeoLocation {
        int256 latitude;
        int256 longitude;
    }

    mapping(address => bool) public authorizedSigners;
    mapping(uint256 => mapping(address => bool)) public confirmations;
    uint256 public requiredConfirmations;

    uint256 public factorOfLight;

    address private oracle;
    bytes32 private jobId;
    uint256 private fee;

    constructor(
        uint256 _requiredConfirmations,
        address _oracle,
        bytes32 _jobId,
        uint256 _fee
    ) ERC721("ZURIE", "VIFO") {
        requiredConfirmations = _requiredConfirmations;
        oracle = _oracle;
        jobId = _jobId;
        fee = _fee;
    }

    modifier onlyAuthorizedSigner() {
        require(authorizedSigners[msg.sender], "Not an authorized signer");
        _;
    }

    modifier onlySeedOwner(uint256 _seedId) {
        require(seedToAddress[_seedId] == msg.sender, "Not the seed owner");
        _;
    }

    modifier onlyValidCoordinates(int256 _latitude, int256 _longitude) {
        require(_latitude >= -90 && _latitude <= 90, "Invalid latitude");
        require(_longitude >= -180 && _longitude <= 180, "Invalid longitude");
        _;
    }

    function setZuraTokenContract(
        address _zuraTokenAddress
    ) external onlyOwner {
        zuraToken = ZuraToken(_zuraTokenAddress);
    }

    function authorizeSigner(address _signer) public onlyOwner {
        authorizedSigners[_signer] = true;
    }

    function confirmAction(uint256 _seedId) public onlyAuthorizedSigner {
        confirmations[_seedId][msg.sender] = true;

        if (checkRequiredConfirmations(_seedId)) {
            executeAction(_seedId);
        }
    }

    function checkRequiredConfirmations(
        uint256 _seedId
    ) internal view returns (bool) {
        uint256 count;
        for (uint256 i = 0; i < requiredConfirmations; i++) {
            if (confirmations[_seedId][authorizedSigners[i]]) {
                count++;
                if (count >= requiredConfirmations) {
                    return true;
                }
            }
        }
        return false;
    }

    function executeAction(uint256 _seedId) internal {
        require(
            seedStages[_seedId] == Stages.tree,
            "Action can only be executed for a fully grown tree"
        );
        MintableNFT nftContract = MintableNFT(nftContractAddress);
        nftContract.mint(msg.sender, _seedId);
    }

    function getSeed(
        int256 _latitude,
        int256 _longitude
    ) public onlyValidCoordinates {
        require(
            block.timestamp > addressToGetSeedTime[msg.sender],
            "Wait for 1 day to get seed once again"
        );
        seedId++;
        mint(msg.sender, seedId);
        seedToAddress[seedId] = msg.sender;
        addressToGetSeedTime[msg.sender] = block.timestamp + 1 days;
        trackWatering[seedId] = block.timestamp + 1 days;
        seedOriginTime[seedId] = block.timestamp;
        fullyGrowthTimeOfSeed[seedId] = block.timestamp + 15 days;
        seedIsLive[seedId] = true;
        seedCoordinates[seedId] = GeoLocation(_latitude, _longitude);
        requestFactorOfLight(_latitude, _longitude);
    }

    function giveWater(uint256 _seedId) public payable {
        require(_seedId > 0 && _seedId <= seedId, "Invalid seed ID");
        require(
            seedStages[_seedId] != Stages.tree || seedIsLive[_seedId],
            "No need to water your tree"
        );

        address seedOwner = seedToAddress[_seedId];
        require(
            msg.sender == seedToAddress[_seedId] ||
                msg.sender == approvedAddresses[seedOwner] ||
                authorizedSigners[msg.sender],
            "Unauthorized"
        );

        uint256 currentTime = block.timestamp;
        uint256 seedOriginPlus15Days = seedOriginTime[_seedId] + 15 days;

        if (currentTime > trackWatering[_seedId]) {
            if (currentTime <= seedOriginPlus15Days) {
                // Seed dies if not watered within 15 days
                seedIsLive[_seedId] = false;
                revert("Your seed is now dead");
            }

            // Extend the growth time by 2 days
            fullyGrowthTimeOfSeed[_seedId] += 2 days;
            trackWatering[_seedId] = currentTime + 1 days;
        } else if (currentTime > seedOriginTime[_seedId] + 30 days) {
            // After 30 days, seed becomes a sapling if not watered
            require(currentTime < seedOriginPlus15Days);
            seedStages[_seedId] = Stages.sapling;
            trackWatering[_seedId] = currentTime + 1 days;
        } else {
            // Update last watering time
            trackWatering[_seedId] = currentTime + 1 days;
        }

        if (
            currentTime >= seedOriginPlus15Days &&
            currentTime >= fullyGrowthTimeOfSeed[_seedId]
        ) {
            // Seed becomes a tree if fully grown
            seedStages[_seedId] = Stages.tree;
            mint(msg.sender, _seedId);
        }

        // metadata attributes using IPFS
        // IPFS metadata code here...

        emit Watered(_seedId, msg.sender);
    }

    event Watered(uint256 indexed seedId, address indexed sender);

    function requestFactorOfLight(
        int256 _latitude,
        int256 _longitude
    ) internal {
        Chainlink.Request memory request = buildChainlinkRequest(
            jobId,
            address(this),
            this.fulfillFactorOfLight.selector
        );
        request.add("lat", uint2str(uint256(_latitude)));
        request.add("lon", uint2str(uint256(_longitude)));
        request.add("copyPath", "current.light");
        request.add("type", "uint256");
        bytes32 requestId = sendChainlinkRequestTo(oracle, request, fee);

        pendingRequests[requestId] = seedId; // Use seedId directly
    }

    function buyManure(
        uint256 _mannureId,
        uint256 _seedId,
        uint256 _amount
    ) external {
        require(
            isPlayer[msg.sender] && !usedMannure[_mannureId],
            "Invalid operation"
        );
        require(
            zuraToken.balanceOf(msg.sender) >= _amount,
            "Insufficient ZuraTokens"
        );

        fullyGrowthTimeOfSeed[_seedId] -= 3 days;
        usedMannure[_mannureId] = true;

        zuraToken.transferFrom(msg.sender, address(this), _amount); // Transfer ZuraTokens to the contract
    }

    function fulfillFactorOfLight(
        bytes32 _requestId,
        uint256 _factorOfLight
    ) public recordChainlinkFulfillment(_requestId) {
        uint256 _seedId = pendingRequests[_requestId];
        require(_seedId > 0 && _seedId <= seedId, "Invalid seed ID");

        if (_factorOfLight <= factorOfLight) {
            // Seed is getting enough light
        } else {
            // Updating the status
        }
        delete pendingRequests[_requestId];
    }

    function mint(address _to, uint256 _tokenId) internal {
        _safeMint(_to, _tokenId);
    }
}
