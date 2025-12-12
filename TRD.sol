// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IDEXFactory {
	/// @notice Creates a pair for two tokens
	function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IDEXRouter {
	/// @notice Returns the factory address
	function factory() external pure returns (address);
	
	/// @notice Returns the WETH token address
	function WETH() external pure returns (address);
	
	/**
     * @notice Swaps an exact amount of tokens for ETH, supporting tokens with transfer fees
     * @param amountIn Amount of tokens to send
     * @param amountOutMin Minimum amount of ETH to receive
     * @param path Token swap path
     * @param to Recipient of ETH
     * @param deadline Expiration timestamp for transaction
     */
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

contract TRD is ERC20, Ownable {

	address private pair;
	IDEXRouter private router;
	
	/// @notice Address receiving marketing fees
	address public marketingWallet;
	
	 /// @notice [0]: Buy fee, [1]: Sell fee
	uint256[2] public marketingFee;
	
	 /// @notice Maximum total token supply
	uint256 public immutable maxSupply;
	
	/// @notice Divider used to calculate fee percentages
	uint256 public immutable divider;
	
	/// @notice Maximum fee allowed (e.g., 1000 = 10%)
	uint256 public immutable maxAllowedFee;
	
	/// @notice Minimum allowed threshold for token-to-ETH swaps
	uint256 public immutable minAllowedSwapThreshold;
	
	/// @notice Token balance threshold to trigger a swap for ETH
	uint256 public tokenSwapThreshold;
	
	bool private swapping;
	
	/// @notice Wallets excluded from paying fees
	mapping(address => bool) public feeExemptWallet;
	
	/// @notice Pairs used for determining buy/sell operations
	mapping(address => bool) public liquidityPair;
	
	/// @notice Emitted when token swap threshold is updated
    event TokenSwapThresholdSet(uint256 amount);

    /// @notice Emitted when liquidity pair status is updated
    event LiquidityPairStatusSet(address indexed pair, bool value);

    /// @notice Emitted when a wallet’s fee exemption is set
    event FeeExemptionSet(address indexed wallet, bool value);

    /// @notice Emitted when the marketing wallet is set
    event MarketingWalletSet(address indexed wallet);

    /// @notice Emitted when marketing fees are updated
    event MarketingFeeSet(uint256 buy, uint256 sell);
	
	/**
     * @notice Constructor to initialize the token and mint supply to specific wallets
     * @param ownerWallet Address of the contract owner
    */
    constructor(address ownerWallet) ERC20("TRD Network", "TRD") {
		require(address(ownerWallet) != address(0), "Zero address");
		
		router = IDEXRouter(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
		pair = IDEXFactory(router.factory()).createPair(address(this), router.WETH());
		
		maxSupply = 3_300_000_000 * (10**18);
		tokenSwapThreshold = 50_000 * (10**18);
		minAllowedSwapThreshold = 100 * (10**18);
		divider = 10000;
		maxAllowedFee = 1000;
		
		liquidityPair[address(pair)] = true;
		feeExemptWallet[address(this)] = true;
		
		// Initial token distribution
		_mint(0xFfB5b770d37574adcBd6d8E485DEC975E970E5E5, 1_650_000_000 * (10**18)); // 1.65 Billion Token For Lock Till 2030
		_mint(0x7EBE1c5fB25D9Ad592EBED05f2EbD57fb55b73Ab, 	660_000_000 * (10**18)); // 660 Million Token For Presale
		_mint(0x52793eAb8f9F2A24f92d558184b5a2A632Efd434, 	231_000_000 * (10**18)); // 231 Million Token For Liquidity
		_mint(0x90f309f96cBBb34f55A6d955b7c4adDF037F4f3D, 	231_000_000 * (10**18)); // 231 Million Token For Reward, Comm, Airdrop
		_mint(0x6Fa45C36C40dfAAce05f3d4D84369B61a33B903f, 	165_000_000 * (10**18)); // 165 Million Token For Ecosystem
		_mint(0x6632173845CBC82e34dd3Df29F1f110bdA579264, 	165_000_000 * (10**18)); // 165 Million Token For Marketing
		_mint(0xab3B34473d8eaBf7379b8924700993560Bbe27D8, 	 99_000_000 * (10**18)); // 99 Million Token For Team
		_mint(0x5c9230E388F2bE139cb3f6b31ED4EE43D67e03Ff, 	 99_000_000 * (10**18)); // 99 Million Token For Development
		
		_transferOwnership(address(ownerWallet));
    }
	
	/**
     * @notice Internal mint with max supply check and fee exemption
     * @param wallet Wallet to receive tokens
     * @param amount Token amount to mint
    */
	function _mint(address wallet, uint256 amount) internal override {
		require(totalSupply() + amount <= maxSupply, "Exceeds max supply");
		
		feeExemptWallet[wallet] = true;
		super._mint(wallet, amount);
	}
	
	/**
     * @notice Set a wallet’s fee exemption status
     * @param wallet Wallet address
     * @param status True to exempt from fees
     */
	function setFeeExemption(address wallet, bool status) external onlyOwner {
        require(wallet != address(0), "Zero address");
		require(feeExemptWallet[wallet] != status, "Wallet already in desired status");
		
		feeExemptWallet[wallet] = status;
        emit FeeExemptionSet(wallet, status);
    }
	
	/**
     * @notice Set threshold to trigger token swap for ETH
     * @param amount Token threshold amount
     */
	function setTokenSwapThreshold(uint256 amount) external onlyOwner {
  	    require(amount <= totalSupply(), "Amount cannot be over the total supply.");
		require(amount >= minAllowedSwapThreshold, "Amount cannot be less than min. allowed swap threshold.");
		
		tokenSwapThreshold = amount;
		emit TokenSwapThresholdSet(amount);
  	}
	
	/**
     * @notice Set or unset an address as a liquidity pair
     * @param newPair Address to set
     * @param value True to treat as LP pair
     */
	function setLiquidityPairStatus(address newPair, bool value) external onlyOwner {
		require(newPair != address(0), "Zero address");
		require(liquidityPair[newPair] != value, "Pair is already the value of 'value'");
		
        liquidityPair[newPair] = value;
        emit LiquidityPairStatusSet(newPair, value);
    }
	
	/**
     * @notice Set the marketing wallet
     * @param newWallet Address of marketing wallet
     */
	function setMarketingWallet(address newWallet) external onlyOwner {
		require(newWallet != address(0), "Zero address");
		
		marketingWallet = newWallet;
        emit MarketingWalletSet(newWallet);
    }
	
	/**
     * @notice Set buy and sell fees for marketing
     * @param buy Fee for buy (in basis points)
     * @param sell Fee for sell (in basis points)
     */
	function setMarketingFee(uint256 buy, uint256 sell) external onlyOwner {
		require(buy <= maxAllowedFee, "Buy fee exceeds allowed maximum");
		require(sell <= maxAllowedFee, "Sell fee exceeds allowed maximum");
		
		marketingFee[0] = buy;
		marketingFee[1] = sell;
		emit MarketingFeeSet(buy, sell);
	}
	
	/**
     * @dev Overrides ERC20 _transfer to include fee and swap logic
     */
	function _transfer(address sender, address recipient, uint256 amount) internal override(ERC20) {      
		bool isSenderFeeExempt = feeExemptWallet[sender];
		bool isRecipientFeeExempt = feeExemptWallet[recipient];
		bool isSenderLPPair = liquidityPair[sender];
		bool isRecipientLPPair = liquidityPair[recipient];
		bool takeFee = !(isSenderFeeExempt || isRecipientFeeExempt || (!isSenderLPPair && !isRecipientLPPair));
	
		if(!swapping && isRecipientLPPair && marketingWallet != address(0))
		{
			uint256 contractTokenBalance = balanceOf(address(this));
			if (contractTokenBalance >= tokenSwapThreshold)
			{
				swapping = true;
				executeTokenSwapForETH(tokenSwapThreshold);
				swapping = false;
			}
		}
		
		if(!takeFee)
		{
			super._transfer(sender, recipient, amount);
		}
		else
		{
			uint256 fee = calculateFee(amount, isRecipientLPPair);
		    if(fee > 0) 
			{
				super._transfer(sender, address(this), fee);
		    }
		    super._transfer(sender, recipient, (amount - fee));
		}
    }
	
	/**
     * @notice Calculate fee for transfer
     * @param amount Amount being transferred
     * @param sell Whether it's a sell operation
     * @return Calculated fee amount
    */
	function calculateFee(uint256 amount, bool sell) private view returns (uint256) {
		uint256 newFee = (amount * (sell ? marketingFee[1] : marketingFee[0])) / (divider);
		return newFee;
    }
	
	/**
     * @notice Swaps tokens from contract balance for ETH and sends to marketing wallet
     * @param amount Amount of tokens to swap
    */
	function executeTokenSwapForETH(uint256 amount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();
		
        _approve(address(this), address(router), amount);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(marketingWallet),
            block.timestamp
        );
    }
}