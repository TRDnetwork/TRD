//SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// @title Chainlink Aggregator Interface
/// @notice Interface to interact with Chainlink Price Feeds
/// @dev This interface allows fetching the latest round data from a Chainlink aggregator
interface Aggregator {
	 /**
     * @notice Returns the latest round data
     * @dev Reverts if no data is present
     * @return roundId The round ID
     * @return answer The latest price or answer (could be negative if defined that way)
     * @return startedAt Timestamp of when the round started
     * @return updatedAt Timestamp of when the answer was last updated
     * @return answeredInRound The round ID in which the answer was computed
     */
	function latestRoundData()
		external
		view
		returns (
			uint80 roundId,
			int256 answer,
			uint256 startedAt,
			uint256 updatedAt,
			uint80 answeredInRound
		);
}

/// @title TRD Presale Contract
/// @notice Handles presale of TRD tokens using USDC, USDT, or ETH, with referral and bonus mechanisms
/// @dev Utilizes OpenZeppelin libraries for security and utility
contract Presale is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

	/// @notice Total tokens sold during the presale
	uint256 private soldToken;

	/// @notice Total tokens distributed as referral rewards
	uint256 private referralToken;

	/// @notice Total tokens distributed as bonuses
	uint256 private bonusToken;

	/// @notice Total tokens available for claiming (after vesting)
	uint256 private claimableToken;

	/// @notice Total funds raised from presale (in USD equivalent)
	uint256 private fundRaised;
	
	/// @notice Maximum allowable delay (in seconds) for oracle data freshness
	uint256 private immutable maxDelay;
	
	/// @notice Address of the TRD token contract
	address private immutable TRD;

	/// @notice Address of the USDC token contract
	address private immutable USDC;

	/// @notice Address of the USDT token contract
	address private immutable USDT;

	/// @notice Chainlink aggregator interface for ETH/USD price feed
	Aggregator private immutable aggregatorInterface;

	/// @notice Number of weeks over which vesting will occur
	uint256 public immutable vestingWeeks;

	/// @notice Number of tokens released weekly during vesting
	uint256 public immutable weeklyVesting;

	/// @notice Referral bonus percentage (e.g., 500 = 5%)
	uint256 public immutable referralBonus;

	/// @notice Current active sale stage (0-based index)
	uint256 public activeStage;

	/// @notice Divider used to normalize token prices (e.g., 1000 for 3 decimals)
	uint256 public immutable divider;

	/// @notice Timestamp when claim becomes available
	uint256 public claimStartTime;

	/// @notice Boolean flag to enable/disable claim functionality
	bool public claimStatus;

	/// @notice Boolean flag to enable/disable the presale
	bool public saleStatus;

	/// @notice Array storing the number of tokens allocated per stage
	uint256[10] public tokens;

	/// @notice Array storing the price per token at each stage
	uint256[10] public prices;

	/// @notice Struct representing a single deposit made by a user
	/// @param amount Amount deposited
	/// @param depositTime Timestamp of deposit
	/// @param currency Currency used (ETH, USDC, USDT)
	struct Deposit {
		uint256 amount;
		uint256 depositTime;
		string currency;
	}

	/// @notice Struct representing a withdrawal action by a user
	/// @param amount Amount withdrawn
	/// @param withdrawTime Timestamp of withdrawal
	struct Withdrawal {
		uint256 amount;
		uint256 withdrawTime;
	}

	/// @notice Struct containing full token purchase and referral info per user
	struct BuyTokenInfo {
		uint256 USDPaid;               ///< Total USD equivalent paid
		uint256 tokenFromBuy;          ///< Tokens bought directly
		uint256 tokenFromReferral;     ///< Tokens earned from referrals
		uint256 tokenFromBonus;        ///< Tokens earned from bonus tiers
		uint256 claimedToken;          ///< Tokens already claimed
		uint256 referralCount;         ///< Total successful referrals
		uint256 referralUSD;           ///< USD invested by referrals
		string referralCode;           ///< User's unique referral code
		string sponsorCode;            ///< Referral code of sponsor (if any)
		Deposit[] deposits;            ///< List of user deposits
		Withdrawal[] withdrawals;      ///< List of user withdrawals
	}

	/// @notice Struct for leaderboard entries
	/// @param leader Address of the top investor
	/// @param amount Total USD invested by the leader
	struct LeaderBoardInfo {
		address leader;
		uint256 amount;
	}

	/// @notice Struct representing a bonus tier
	/// @param minimumInvestment Minimum investment required for tier eligibility
	/// @param bonusPercentage Bonus percentage awarded for the tier
	struct BonusTier {
		uint256 minimumInvestment;
		uint256 bonusPercentage;
	}

	/// @notice Maps user address to their token purchase and referral info
	mapping(address => BuyTokenInfo) public mapTokenBuyInfo;

	/// @notice Maps referral code to wallet address
	mapping(string => address) public mapReferralWallet;

	/// @notice Maps leaderboard ID to list of top investors
	mapping(uint256 => LeaderBoardInfo[]) public leaderBoard;

	/// @notice Maps bonus tier ID to bonus tier settings
	mapping(uint256 => BonusTier) public bonusTiers;

	/// @notice Emitted when a user successfully purchases tokens
	/// @param user The address of the buyer
	/// @param tokens Number of tokens received
	/// @param amount USD-equivalent value spent
	event TokensBought(address indexed user, uint256 tokens, uint256 amount);

	/// @notice Emitted when a user claims tokens after vesting starts
	/// @param user Address of the claimant
	/// @param amount Number of tokens claimed
	/// @param timestamp Timestamp of the claim
	event TokensClaimed(address indexed user, uint256 amount, uint256 timestamp);

	/// @notice Emitted when the sale status is toggled
	/// @param status New status (true = active, false = inactive)
	event SaleStatusSet(bool status);

	/// @notice Emitted when claim functionality is toggled
	/// @param status New claim status (true = active, false = inactive)
	event ClaimStart(bool status);
	
	/// @notice Constructor initializes sale configuration, pricing, token stages, and referral/bonus tiers
    /// @param ownerWallet The address of the wallet that will own the contract
	constructor(address ownerWallet) {
		require(address(ownerWallet) != address(0), "Zero address");
		
		tokens = [
			 5_000_000 * (10**18), 
			10_000_000 * (10**18), 
			15_000_000 * (10**18), 
			20_000_000 * (10**18), 
			50_000_000 * (10**18), 
			75_000_000 * (10**18), 
			75_000_000 * (10**18), 
			75_000_000 * (10**18), 
			40_000_000 * (10**18), 
			31_000_000 * (10**18)
		];
		
		prices = [
			  2 * (10**4), 
			  3 * (10**4),	
			  4 * (10**4), 
			  6 * (10**4), 
			  8 * (10**4), 
			 10 * (10**4), 
			 15 * (10**4), 
			 20 * (10**4), 
			 25 * (10**4), 
			 35 * (10**4)
		];
		
		addBonusTier(0, 2500 * 10**6, 1500); 
		addBonusTier(1, 1000 * 10**6, 1000); 
		addBonusTier(2, 500 * 10**6, 750);   
		addBonusTier(3, 250 * 10**6, 500);
		
		vestingWeeks = 20;
		referralBonus = 1000;
		weeklyVesting = 500;
		divider = 10000;
		maxDelay = 10800;
		
		TRD = address(0xEa059F3f1106aA0Ddd1550b1cc37Fc195a559Ef9);
		USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
		USDT = address(0xdAC17F958D2ee523a2206206994597C13D831ec7);
		aggregatorInterface = Aggregator(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
		_transferOwnership(address(ownerWallet));
    }
	
	/// @notice Internal function to add a bonus tier
    /// @param id Tier ID
    /// @param investment Minimum investment in USD
    /// @param bonus Bonus percentage
	function addBonusTier(uint256 id, uint256 investment, uint256 bonus) internal {
		bonusTiers[id] = BonusTier({
			minimumInvestment: investment,
			bonusPercentage: bonus
		});
	}
	
	/// @notice Buy tokens using USDC
    /// @param amount The amount of USDC to spend
    /// @param sponsorCode Referral code of the sponsor (if any)
	function buyWithUSDC(uint256 amount, string memory sponsorCode) external nonReentrant {
		require(saleStatus, "Sale has not started yet");
		require(IERC20(USDC).balanceOf(msg.sender) >= amount, "Insufficient USDC balance to buy tokens");
		require(IERC20(USDC).allowance(msg.sender, address(this)) >= amount, "Insufficient USDC allowance; approve tokens first");
	   
		uint256 token = (amount * 10**18) / prices[activeStage];
		
		_buytokens(amount, amount, token, msg.sender, sponsorCode, "USDC");
		IERC20(USDC).safeTransferFrom(address(msg.sender), address(this), amount);
		emit TokensBought(msg.sender, token, amount);
    }
	
	/// @notice Buy tokens using USDT
    /// @param amount The amount of USDT to spend
    /// @param sponsorCode Referral code of the sponsor (if any)
	function buyWithUSDT(uint256 amount, string memory sponsorCode) external nonReentrant {
		require(saleStatus, "Sale has not started yet");
		require(IERC20(USDT).balanceOf(msg.sender) >= amount, "Insufficient USDT balance to buy tokens");
		require(IERC20(USDT).allowance(msg.sender, address(this)) >= amount, "Insufficient USDT allowance; approve tokens first");
	   
		uint256 token = (amount * 10**18) / prices[activeStage];
		
		_buytokens(amount, amount, token, msg.sender, sponsorCode, "USDT");
		IERC20(USDT).safeTransferFrom(address(msg.sender), address(this), amount);
		emit TokensBought(msg.sender, token, amount);
    }
	
	/// @notice Buy tokens using ETH
    /// @param sponsorCode Referral code of the sponsor (if any)
	function buyWithETH(string memory sponsorCode) external payable nonReentrant {
		(uint256 adjustedPrice, uint256 lastUpdated) = getLatestPrice();
		
		require(lastUpdated >= block.timestamp - maxDelay, "Stale oracle data: price too old");
		uint256 amount = (adjustedPrice * msg.value) / (10**30);
		require(saleStatus, "Sale has not started yet");
		
		uint256 token = (amount * 10**18) / prices[activeStage];
		
	    _buytokens(msg.value, amount, token, msg.sender, sponsorCode, "ETH");
		emit TokensBought(msg.sender, token, amount);
    }
	
	/// @notice Core internal token purchase logic
    /// @param invested Raw investment value (ETH or token units)
    /// @param amount Normalized amount in USD
    /// @param token Number of TRD tokens to assign
    /// @param buyer Address of the buyer
    /// @param scode Sponsor referral code
    /// @param currency Currency used for payment (ETH, USDC, USDT)
	function _buytokens(uint256 invested, uint256 amount, uint256 token, address buyer, string memory scode, string memory currency) internal {
		require(token > 0, "Token amount must be greater than zero");
		require(tokens[activeStage] >= token, "Not enough tokens remaining in this stage");
		
		BuyTokenInfo storage buyerInfo = mapTokenBuyInfo[buyer];
		if(buyerInfo.USDPaid == 0) {
			string memory rcode = generateReferralCode(buyer);
			
			mapReferralWallet[rcode] = buyer;
			buyerInfo.referralCode = rcode;
			if(mapReferralWallet[scode] != address(0)) 
			{
				require(keccak256(bytes(rcode)) != keccak256(bytes(scode)), "Referral code must be different from sponsor code");
				buyerInfo.sponsorCode = scode;
				mapTokenBuyInfo[mapReferralWallet[buyerInfo.sponsorCode]].referralCount += 1;
			}
		}
		
		if(mapReferralWallet[buyerInfo.sponsorCode] != address(0)) {
			BuyTokenInfo storage sponsorInfo = mapTokenBuyInfo[mapReferralWallet[buyerInfo.sponsorCode]];
			
			uint256 rToken = (token * referralBonus) / (divider);
			sponsorInfo.tokenFromReferral += rToken;
			sponsorInfo.referralUSD += amount;
			
			referralToken += rToken;
			claimableToken += rToken;
		}
		
		tokens[activeStage] -= token;
		fundRaised += amount;
		soldToken += token; 
		claimableToken += token;
		
		buyerInfo.USDPaid += amount;
		buyerInfo.tokenFromBuy += token;
		buyerInfo.deposits.push(Deposit(invested, block.timestamp, currency));
		
		uint256 bonusPercentage = calculateBonus(buyerInfo.USDPaid);
		if(bonusPercentage > 0) {
			uint256 bonus = (token * bonusPercentage) / (divider);
			buyerInfo.tokenFromBonus += bonus;
			claimableToken += bonus;
			bonusToken += bonus;
		}
		
		addTopLeader(msg.sender, buyerInfo.USDPaid);
		
		if((1* 10**18) > tokens[activeStage]) {
			if(activeStage == (tokens.length - 1)) {
				saleStatus = false;
			} else {
				activeStage++;
			}
		}
	}
	
	/// @notice Calculates applicable bonus percentage based on total USD investment
    /// @param investment Total USD amount invested by user
    /// @return Bonus percentage (e.g., 1000 = 10%)
	function calculateBonus(uint256 investment) public view returns (uint256) {
		if (investment >= bonusTiers[0].minimumInvestment) {
			return bonusTiers[0].bonusPercentage;
		} else if (investment >= bonusTiers[1].minimumInvestment) {
			return bonusTiers[1].bonusPercentage;
		} else if (investment >= bonusTiers[2].minimumInvestment) {
			return bonusTiers[2].bonusPercentage;
		} else if (investment >= bonusTiers[3].minimumInvestment) {
			return bonusTiers[3].bonusPercentage;
		} else {
			return 0;
		}
	}
	
	/// @notice Adds user to leaderboard if eligible
    /// @param leader The address of the investor
    /// @param amount Total investment amount
	function addTopLeader(address leader, uint256 amount) private {
		LeaderBoardInfo[] storage topLeaders = leaderBoard[0];
		
		for (uint256 i = 0; i < topLeaders.length; i++) {
			if (topLeaders[i].leader == leader) {
				topLeaders[i].amount = amount;
				quickSort(0, 0, topLeaders.length - 1);
				return;
			}
		}
		
		if (topLeaders.length < 50) {
			topLeaders.push(LeaderBoardInfo(leader, amount));
			quickSort(0, 0, topLeaders.length - 1);
		} else {
			if (topLeaders[0].amount < amount) {
				topLeaders[0] = LeaderBoardInfo(leader, amount);
				quickSort(0, 0, topLeaders.length - 1);
			}
		}
	}
	
	/// @notice Checks if an address is on the leaderboard
    /// @param leader The address to check
    /// @return Boolean indicating whether the address is a top leader
	function checkTopLeader(address leader) external view returns (bool){
        LeaderBoardInfo[] storage topLeaders = leaderBoard[0];
		
        for (uint256 i = 0; i < topLeaders.length; i++) {
            if (topLeaders[i].leader == leader) {
				return true;
            }
        }
		return false;
    }
	
	/// @notice Returns all buy transactions (deposits) of a user
    /// @param user Address of the user
    /// @return Array of deposits
	function getBuyTransactions(address user) external view  returns (Deposit[] memory) {
		BuyTokenInfo storage info = mapTokenBuyInfo[user];
		return info.deposits;
	}
	
	/// @notice Returns all withdrawal transactions of a user
    /// @param user Address of the user
    /// @return Array of withdrawals
	function getWithdrawalTransactions(address user) external view  returns (Withdrawal[] memory) {
		BuyTokenInfo storage info = mapTokenBuyInfo[user];
		return info.withdrawals;
	}
	
	/// @notice Gets full leaderboard
    /// @return Array of LeaderBoardInfo
	function getLeaderBoard() external view returns (LeaderBoardInfo[] memory) {
		return leaderBoard[0];
	}
	
	/// @notice Gets leaderboard entries in a specific range
    /// @param start Starting index
    /// @param end Ending index
    /// @return LeaderBoardInfo array
	function getLeaderBoardRange(uint256 start, uint256 end) external view returns (LeaderBoardInfo[] memory) {
		LeaderBoardInfo[] storage fullBoard = leaderBoard[0];
		require(start <= end, "Invalid range");
		require(end < fullBoard.length, "End index out of bounds");

		uint256 length = end - start + 1;
		LeaderBoardInfo[] memory range = new LeaderBoardInfo[](length);

		for (uint256 i = 0; i < length; i++) {
			range[i] = fullBoard[start + i];
		}
		
		return range;
	}
	
	/// @notice Gets deposit history range for a user
    /// @param user Address of the user
    /// @param start Start index
    /// @param end End index
    /// @return Array of deposits
	function getBuyRange(address user, uint256 start, uint256 end) external view returns (Deposit[] memory) {
		Deposit[] storage deposits = mapTokenBuyInfo[user].deposits;
		require(start <= end, "Invalid range");
		require(end < deposits.length, "End index out of bounds");

		uint256 length = end - start + 1;
		Deposit[] memory range = new Deposit[](length);

		for (uint256 i = 0; i < length; i++) {
			range[i] = deposits[start + i];
		}

		return range;
	}
	
	/// @notice Gets withdrawal history range for a user
    /// @param user Address of the user
    /// @param start Start index
    /// @param end End index
    /// @return Array of withdrawals
	function getWithdrawalRange(address user, uint256 start, uint256 end) external view returns (Withdrawal[] memory) {
		Withdrawal[] storage withdrawals = mapTokenBuyInfo[user].withdrawals;
		require(start <= end, "Invalid range");
		require(end < withdrawals.length, "End index out of bounds");

		uint256 length = end - start + 1;
		Withdrawal[] memory range = new Withdrawal[](length);

		for (uint256 i = 0; i < length; i++) {
			range[i] = withdrawals[start + i];
		}

		return range;
	}
	
	/// @notice Returns current token price of active stage
    /// @return Current token price
	function getCurrentPrice() external view returns (uint256) {
		return prices[activeStage];
	}
	
	/// @notice Returns presale summary statistics
    /// @return soldToken, referralToken, bonusToken, claimableToken, fundRaised
	function getPresaleStats() external view returns (uint256, uint256, uint256, uint256, uint256) {
		return (soldToken, referralToken, bonusToken, claimableToken, fundRaised);
	}
	
	/// @notice Internal quick sort used to update leaderboard
    /// @param id Leaderboard ID
    /// @param left Start index
    /// @param right End index
	function quickSort(uint256 id, uint256 left, uint256 right) internal {
		LeaderBoardInfo[] storage topLeader = leaderBoard[id];
		if (left >= right) return;
		
		uint256 mid = (left + right) / 2;
		uint256 pivot = topLeader[mid].amount;
		uint256 i = left;
		uint256 j = right;
		
		while (i <= j) {
			while (topLeader[i].amount < pivot) i++;
			while (topLeader[j].amount > pivot) j--;
			
			if (i <= j) {
				(topLeader[i].amount, topLeader[j].amount) = (topLeader[j].amount, topLeader[i].amount);
				(topLeader[i].leader, topLeader[j].leader) = (topLeader[j].leader, topLeader[i].leader);
				i++;
				if (j > 0) j--;
			}
		}
		if (left < j) quickSort(id, left, j);
		if (i < right) quickSort(id, i, right);
	}

	 /// @notice Allows users to claim tokens according to vesting schedule
	function claimTokens() external nonReentrant {
		require(claimStatus, "Claiming is not active");
		
		
		uint256 tokensToClaim = pendingToClaim(msg.sender);
		require(tokensToClaim > 0, "No tokens available to claim yet");
		
		BuyTokenInfo storage buyer = mapTokenBuyInfo[msg.sender];
		buyer.claimedToken += tokensToClaim;
		IERC20(TRD).safeTransfer(msg.sender, tokensToClaim);
		buyer.withdrawals.push(Withdrawal(tokensToClaim, block.timestamp));
		
		emit TokensClaimed(msg.sender, tokensToClaim, block.timestamp);
	}
	
	/// @notice Calculates tokens pending to be claimed by user
    /// @param user Address of the user
    /// @return Amount of tokens pending to be claimed
	function pendingToClaim(address user) public view returns (uint256) {
		if(claimStatus)
		{
			BuyTokenInfo storage buyer = mapTokenBuyInfo[user];
			uint256 totalTokens = buyer.tokenFromBuy + buyer.tokenFromReferral + buyer.tokenFromBonus;
			if(totalTokens > 0)
			{
				uint256 weeksPassed = ((block.timestamp - claimStartTime) / 1 weeks) + 1;
				if (weeksPassed > vestingWeeks) 
				{
					weeksPassed = vestingWeeks;
				}
				uint256 totalClaimable = (totalTokens * weeksPassed * weeklyVesting) / divider;
				return (totalClaimable - buyer.claimedToken);
			}
			else
			{
				return 0;
			}
		}
		else
		{
			return 0;
		}
	}
	
	/// @notice Sets presale active or inactive
    /// @param status Boolean value to set sale active or inactive
	function setSaleStatus(bool status) external onlyOwner {
        require(saleStatus != status, "Sale is already set to that value");
		if(status) 
		{
			require(!claimStatus, "Cannot re-activate sale after claim started");
		}
        saleStatus = status;
		emit SaleStatusSet(status);
    }
	
	/// @notice Starts the claim process after sale ends
	function startClaim() external onlyOwner {
        require(!claimStatus, "Claim already start");
		require(!saleStatus, "Stop the sale to start the claim");
		
		uint256 availableTokens = IERC20(TRD).balanceOf(address(this));
		require(availableTokens >= claimableToken, "Tokens not available to claim");
		
		if(availableTokens > claimableToken)
		{
			IERC20(TRD).safeTransfer(msg.sender, (availableTokens - claimableToken));
		}
		claimStartTime = block.timestamp;
		claimStatus = true;
		emit ClaimStart(true);
    }
	
	/// @notice Allows the owner to withdraw collected funds (ETH, USDC, USDT)
    /// @param receiver The address to receive the funds
	function withdrawFunds(address payable receiver) external onlyOwner nonReentrant {
		require(receiver != address(0), "Invalid address");
		
		uint256 USDTBalance = IERC20(USDT).balanceOf(address(this));
		if (USDTBalance > 0) {
			IERC20(USDT).safeTransfer(receiver, USDTBalance);
		}
		
		uint256 USDCBalance = IERC20(USDC).balanceOf(address(this));
		if (USDCBalance > 0) {
			IERC20(USDC).safeTransfer(receiver, USDCBalance);
		}
		
		uint256 ETHBalance = address(this).balance;
		if (ETHBalance > 0) {
			(bool sent, ) = receiver.call{value: ETHBalance}("");
			require(sent, "ETH withdrawal failed");
		}
	}
	
	/// @notice Allows the owner to manually skip to the next sale stage
	function skipToNextStage() external onlyOwner {
		require(activeStage < tokens.length - 1, "Already at last stage");
		activeStage++;
	}
	
	/// @notice Gets latest ETH/USD price from Chainlink oracle
	/// @return adjustedPrice Price adjusted to 18 decimals
	/// @return lastUpdated Timestamp when the price was last updated
	function getLatestPrice() public view returns (uint256, uint256) {
		(, int256 rawPrice, , uint256 lastUpdated, ) = aggregatorInterface.latestRoundData();
		uint256 adjustedPrice = uint256(rawPrice) * (10 ** 10);
		return (adjustedPrice, lastUpdated);
	}
	
	/// @notice Generates a unique referral code for a given user address
	/// @dev Converts the address to a 40-character hexadecimal string (without '0x')
	/// @param user The address of the user to generate the referral code for
	/// @return A string representing the referral code in hexadecimal format
	function generateReferralCode(address user) public pure returns (string memory) {
		return Strings.toHexString(uint160(user), 20);
	}
}
