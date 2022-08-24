import { assert, expect } from "chai";
import { BigNumber } from "bignumber.js";
import { ethers, network } from "hardhat";
import {
  IERC20,
  IUniswapV3Factory,
  IUniswapV3Pool,
  SwapTest,
  SSUniVault,
  SSUniFactory,
  EIP173Proxy,
} from "../typechain";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import { BigNumberish } from "ethers";


describe("SSUniVault", () => {
  // eslint-disable-next-line
  BigNumber.config({ EXPONENTIAL_AT: 999999, DECIMAL_PLACES: 40 });

  // returns the sqrt price as a 64x96
  function encodePriceSqrt(reserve1: string, reserve0: string) {
    return new BigNumber(reserve1)
      .div(reserve0)
      .sqrt()
      .multipliedBy(new BigNumber(2).pow(96))
      .integerValue(3)
      .toString();
  }

  function position(address: string, lowerTick: number, upperTick: number) {
    return ethers.utils.solidityKeccak256(
      ["address", "int24", "int24"],
      [address, lowerTick, upperTick]
    );
  }
  async function mint (
    vault: SSUniVault,
    amount0: BigNumberish, 
    amount1: BigNumberish,
    receiver: string
    ){
      const result = await vault.getMintAmounts(amount0,amount1);
      await vault.mint(result.mintAmount, receiver);
  }

  let uniswapFactory: IUniswapV3Factory;
  let uniswapPool: IUniswapV3Pool;

  let token0: IERC20;
  let token1: IERC20;
  let user0: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let swapTest: SwapTest;
  let sSUniVault: SSUniVault;
  let sSUniFactory: SSUniFactory;
  let gelato: SignerWithAddress;
  let uniswapPoolAddress: string;
  let implementationAddress: string;

  before(async function () {
    [user0, user1, user2, gelato] = await ethers.getSigners();

    const swapTestFactory = await ethers.getContractFactory("SwapTest");
    swapTest = (await swapTestFactory.deploy()) as SwapTest;
  });

  beforeEach(async function () {
    const uniswapV3Factory = await ethers.getContractFactory(
      "UniswapV3Factory"
    );
    const uniswapDeploy = await uniswapV3Factory.deploy();
    uniswapFactory = (await ethers.getContractAt(
      "IUniswapV3Factory",
      uniswapDeploy.address
    )) as IUniswapV3Factory;

    const mockERC20Factory = await ethers.getContractFactory("MockERC20");
    token0 = (await mockERC20Factory.deploy({ gasLimit: 30000000 })) as IERC20;
    token1 = (await mockERC20Factory.deploy({ gasLimit: 30000000 })) as IERC20;

    await token0.approve(
      swapTest.address,
      ethers.utils.parseEther("10000000000000")
    );
    await token1.approve(
      swapTest.address,
      ethers.utils.parseEther("10000000000000")
    );

    // Sort token0 & token1 so it follows the same order as Uniswap & the sSUniVaultFactory
    if (
      ethers.BigNumber.from(token0.address).gt(
        ethers.BigNumber.from(token1.address)
      )
    ) {
      const tmp = token0;
      token0 = token1;
      token1 = tmp;
    }

    await uniswapFactory.createPool(token0.address, token1.address, "3000");
    uniswapPoolAddress = await uniswapFactory.getPool(
      token0.address,
      token1.address,
      "3000"
    );
    uniswapPool = (await ethers.getContractAt(
      "IUniswapV3Pool",
      uniswapPoolAddress
    )) as IUniswapV3Pool;
    await uniswapPool.initialize(encodePriceSqrt("1", "1"));

    await uniswapPool.increaseObservationCardinalityNext("5");

    const sSUniVaultFactory = await ethers.getContractFactory("SSUniVault");
    const gUniImplementation = await sSUniVaultFactory.deploy(
      await gelato.getAddress()
    );

    implementationAddress = gUniImplementation.address;

    const sSUniFactoryFactory = await ethers.getContractFactory("SSUniFactory");

    sSUniFactory = (await sSUniFactoryFactory.deploy(
      uniswapFactory.address
    )) as SSUniFactory;

    await sSUniFactory.initialize(
      implementationAddress,
      await user0.getAddress()
    );

    const pool = await sSUniFactory.callStatic.createManagedPool(
      token0.address,
      token1.address,
      3000,
      0,
      -887220,
      887220
    );

    await sSUniFactory.createManagedPool(
      token0.address,
      token1.address,
      3000,
      0,
      -887220,
      887220
    );

    const deployers = await sSUniFactory.getDeployers();
    const deployer = deployers[0];
    const pools = await sSUniFactory.getPools(deployer);
    expect(pools.length).to.equal(1);
    expect(pools[0]).to.equal(pool);

    sSUniVault = (await ethers.getContractAt("SSUniVault", pools[0])) as SSUniVault;
  });
  describe("Before liquidity deposited", function () {
    beforeEach(async function () {
      await token0.approve(
        sSUniVault.address,
        ethers.utils.parseEther("1000000")
      );
      await token1.approve(
        sSUniVault.address,
        ethers.utils.parseEther("1000000")
      );
    });
    describe("deposit", function () {
      it("should deposit funds into SSUniVault", async function () {
        await mint(sSUniVault, ethers.utils.parseEther("1"), ethers.utils.parseEther("1"), await user0.getAddress());
        expect(await token0.balanceOf(uniswapPool.address)).to.be.gt(0);
        expect(await token1.balanceOf(uniswapPool.address)).to.be.gt(0);
        const [liquidity] = await uniswapPool.positions(
          position(sSUniVault.address, -887220, 887220)
        );
        expect(liquidity).to.be.gt(0);
        const supply = await sSUniVault.totalSupply();
        expect(supply).to.be.gt(0);

        await mint(sSUniVault, ethers.utils.parseEther("0.5"), ethers.utils.parseEther("1"), await user0.getAddress());
        const [liquidity2] = await uniswapPool.positions(
          position(sSUniVault.address, -887220, 887220)
        );
        assert(liquidity2.gt(liquidity));

        await sSUniVault.transfer(
          await user1.getAddress(),
          ethers.utils.parseEther("1")
        );
        await sSUniVault
          .connect(user1)
          .approve(await user0.getAddress(), ethers.utils.parseEther("1"));
        await sSUniVault
          .connect(user0)
          .transferFrom(
            await user1.getAddress(),
            await user0.getAddress(),
            ethers.utils.parseEther("1")
          );

        const decimals = await sSUniVault.decimals();
        const symbol = await sSUniVault.symbol();
        const name = await sSUniVault.name();
        expect(symbol).to.equal("SS-UNI");
        expect(decimals).to.equal(18);
        expect(name).to.equal("SwapSweep Uniswap TOKEN/TOKEN Vault");
      });
    });
    describe("onlyGelato", function () {
      it("should fail if not called by gelato", async function () {
        const errorMessage = "Gelatofied: Only gelato"
        // TODO: include test case for recenter function as well once thats coded out
        await expect(
          sSUniVault
            .connect(user1)
            .rebalance(
              encodePriceSqrt("10", "1"),
              1000,
              true,
              10,
              token0.address
            )
        ).to.be.revertedWith(errorMessage);
        await expect(
          sSUniVault.connect(user1).withdrawManagerBalance(1, token0.address)
        ).to.be.revertedWith(errorMessage);
      });
      it("should fail if no fees earned", async function () {
        const errorMessage = "high fee"
        // TODO: include test case for recenter function as well once thats coded out
        // deposit liquidity
        await mint(sSUniVault, ethers.utils.parseEther("1"), ethers.utils.parseEther("1"), await user0.getAddress());
        // Update oracle params to ensure checkSlippage computes without error.
        const tx = await sSUniVault
          .connect(user0)
          .updateGelatoParams(
            "9000",
            "9000",
            "500",
            "300",
            await user1.getAddress()
          );
        await tx.wait();
        if (network.provider && tx.blockHash && user0.provider) {
          const block = await user0.provider.getBlock(tx.blockHash);
          const executionTime = block.timestamp + 300;
          await network.provider.send("evm_mine", [executionTime]);
        }
        await sSUniVault.connect(user0).initializeManagerFee(5000);
        await expect(
          sSUniVault
            .connect(gelato)
            .rebalance(
              encodePriceSqrt("10", "1"),
              1000,
              true,
              10,
              token0.address
            )
        ).to.be.revertedWith(errorMessage);
        await expect(
          sSUniVault.connect(gelato).withdrawManagerBalance(1, token0.address)
        ).to.be.revertedWith(errorMessage);
      });
    });
    describe("onlyManager", function () {
      it("should fail if not called by manager", async function () {
        const errorMessage = "Ownable: caller is not the manager"
        await expect(
          sSUniVault
            .connect(gelato)
            .updateGelatoParams(300, 5000, 5000, 5000, await user0.getAddress())
        ).to.be.revertedWith(errorMessage);

        await expect(
          sSUniVault.connect(gelato).transferOwnership(await user1.getAddress())
        ).to.be.revertedWith(errorMessage);
        await expect(sSUniVault.connect(gelato).renounceOwnership()).to.be
          .revertedWith(errorMessage);
        await expect(sSUniVault.connect(gelato).initializeManagerFee(100)).to.be
          .revertedWith(errorMessage);
      });
    });
    describe("after liquidity deposited", function () {

    }) 
  });
});