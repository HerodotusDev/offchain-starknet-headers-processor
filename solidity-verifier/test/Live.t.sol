// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {SharpFactsAggregator} from "../src/SharpFactsAggregator.sol";
import {MockedSharpFactsRegistry} from "../src/mocks/MockFactsRegistry.sol";
import {IStarknet} from "../src/interfaces/IStarknet.sol";
import {console} from "forge-std/Console.sol";

contract Live is Test {
    SharpFactsAggregator aggregator;
    uint256 privateKey;

    constructor() {
        privateKey = vm.envUint("PRIVATE_KEY");
        string memory SEPOLIA_RPC_URL = vm.rpcUrl("sepolia");
        vm.createSelectFork(SEPOLIA_RPC_URL);

        //? For testing of a fully live contract use this:
        // address aggregatorAddress = address(
        //     0x3931D30A45bD56202f1ebE1058D535F595Fa4cd3
        // );
        // aggregator = SharpFactsAggregator(aggregatorAddress);

        //? For debugging and changing the contract code, but using the actual facts registry use this:
        SharpFactsAggregator.AggregatorState
            memory initialAggregatorState = SharpFactsAggregator
                .AggregatorState({
                    poseidonMmrRoot: 0x06759138078831011e3bc0b4a135af21c008dda64586363531697207fb5a2bae,
                    mmrSize: 1,
                    continuableParentHash: 0x07325f4e5ba61ec91288d506cebda2dbd3eb24d7a97c8df83fa0558354fbdb24
                });
        MockedSharpFactsRegistry factsRegistry = MockedSharpFactsRegistry(
            vm.envAddress("FACTS_REGISTRY_ADDRESS")
        );
        IStarknet starknet = IStarknet(
            vm.envAddress("STARKNET_CORE_L1_ADDRESS")
        );

        vm.startBroadcast(privateKey);
        factsRegistry.setValid(
            0x5c38443f2d3e64de0089ce9e96eeeaa38aa5b598efbdedd8825d4317700786d0
        );
        aggregator = new SharpFactsAggregator(factsRegistry, starknet);
        aggregator.initialize(initialAggregatorState);
        vm.stopBroadcast();
    }

    function test_a() external {
        // {
        //     from_block_number_high: 266981,
        //     to_block_number_low: 266979,
        //     block_n_plus_one_parent_hash: "0x07325f4e5ba61ec91288d506cebda2dbd3eb24d7a97c8df83fa0558354fbdb24",
        //     block_n_minus_r_plus_one_parent_hash: "0x04da70ca0327565ceb8b3182156299778f901623412ebe4d336fc722d477448b",
        //     mmr_previous_root_poseidon: "0x06759138078831011e3bc0b4a135af21c008dda64586363531697207fb5a2bae",
        //     mmr_previous_size: 1,
        //     mmr_new_root_poseidon: "0x0184abee7996d0024314f0fe164990e8c8722ea822653e45b8024cd27ca07f20",
        //     mmr_new_size: 7,
        // }

        // [266981, 266979, 3255190071752325527662919535470927917839056211725393101733102840141210966820, 2195202496286939969296121270920273012516211210819292617514993638531380233355, 2921600461849179232597610084551483949436449163481908169507355734771418934190, 1, 686723289031449058245457067313426500718812556509685386354983963672749047584, 7]

        // ['0x412e5', '0x412e3', '0x07325f4e5ba61ec91288d506cebda2dbd3eb24d7a97c8df83fa0558354fbdb24', '0x04da70ca0327565ceb8b3182156299778f901623412ebe4d336fc722d477448b', '0x06759138078831011e3bc0b4a135af21c008dda64586363531697207fb5a2bae', '0x1', '0x0184abee7996d0024314f0fe164990e8c8722ea822653e45b8024cd27ca07f20', '0x7']

        // Logs:
        //     outputs[0] = 266981
        //     outputs[1] = 266979
        //     outputs[2] = 3255190071752325527662919535470927917839056211725393101733102840141210966820
        //     outputs[3] = 2195202496286939969296121270920273012516211210819292617514993638531380233355
        //     outputs[4] = 2921600461849179232597610084551483949436449163481908169507355734771418934190
        //     outputs[5] = 1
        //     outputs[6] = 686723289031449058245457067313426500718812556509685386354983963672749047584
        //     outputs[7] = 7
        //     outputHash = 0xaebe50e8af865de8fc8a38e108ec47c9d1c9eca6aa430adb9b48aee91528a042
        //     fact       = 0x423211a8817a9723b449bb00fa3a46e30ebb849df3766f075c2f6dba4e72c777

        SharpFactsAggregator.JobOutput[]
            memory jobOutputs = new SharpFactsAggregator.JobOutput[](1);

        jobOutputs[0] = SharpFactsAggregator.JobOutput({
            fromBlockNumberHigh: 266981,
            toBlockNumberLow: 266979,
            blockNPlusOneParentHash: 0x07325f4e5ba61ec91288d506cebda2dbd3eb24d7a97c8df83fa0558354fbdb24,
            blockNMinusRPlusOneParentHash: 0x04da70ca0327565ceb8b3182156299778f901623412ebe4d336fc722d477448b,
            mmrPreviousRootPoseidon: 0x06759138078831011e3bc0b4a135af21c008dda64586363531697207fb5a2bae,
            mmrPreviousSize: 1,
            mmrNewRootPoseidon: 0x0184abee7996d0024314f0fe164990e8c8722ea822653e45b8024cd27ca07f20,
            mmrNewSize: 7
        });

        // 0x5c38443f2d3e64de0089ce9e96eeeaa38aa5b598efbdedd8825d4317700786d0

        vm.startBroadcast(privateKey);
        aggregator.aggregateSharpJobs(jobOutputs);
    }
}
