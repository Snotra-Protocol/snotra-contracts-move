#[test_only]
module snotra_sui::nft_staking_tests {
  use sui::test_scenario::{Self, Scenario};
  use sui::clock::{Self};
  use sui::coin::{Self, Coin};
  use sui::object::{Self, UID};
  use sui::transfer;
  use sui::tx_context::{Self};
  use sui::url::{Self, Url};
  use sui::pay::{Self};
  use sui::dynamic_object_field as ofield;

  use std::string::{Self, String};
  use std::option;

  use snotra_sui::nft_staking::{Self, PoolInfo, UserInfo, AdminCap};

  struct NftA has key, store {
    id: UID,
    name: String,
    description: String,
    url: Url,
  }

  struct NftB has key, store {
    id: UID,
    name: String,
    description: String,
    url: Url,
  }

  struct TestRewardCoin has drop {}
  
  struct NFT_STAKING_TESTS has drop {}

  fun init_coin(
    otw: NFT_STAKING_TESTS,
    scenario: &mut Scenario
  ) {
    let ctx = test_scenario::ctx(scenario);
    let (treasury_cap, metadata) = coin::create_currency<NFT_STAKING_TESTS>(
        otw, 
        9, 
        b"TST", 
        b"Test Coin", 
        b"Test Coin to give rewards", 
        option::some(url::new_unsafe_from_bytes(
          b"1.png"
        )), 
        ctx
    );

    let minted_coin = coin::mint(&mut treasury_cap, 1_000_000_000_000_000_000, ctx);
    pay::keep(minted_coin, ctx);

    transfer::public_freeze_object(metadata);
    transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
  }

  fun mint_nft_a(
    alice: address,
    scenario: &mut Scenario
  ) {

    let ctx = test_scenario::ctx(scenario);

    let url = string::utf8(b"url");
    let nft = NftA {
        id: object::new(ctx),
        name: string::utf8(b"test-nft-a"),
        description: string::utf8(b"this is a test-nft-a"),
        url: url::new_unsafe(string::to_ascii(url)),
    };
    transfer::public_transfer(nft, alice);
  }

  fun mint_nft_b(
    alice: address,
    scenario: &mut Scenario
  ) {

    let ctx = test_scenario::ctx(scenario);

    let url = string::utf8(b"url");
    let nft = NftB {
        id: object::new(ctx),
        name: string::utf8(b"test-nft-b"),
        description: string::utf8(b"this is a test-nft-b"),
        url: url::new_unsafe(string::to_ascii(url)),
    };
    transfer::public_transfer(nft, alice);
  }

  #[test]
  public fun e2e_test_stake_claim_unstake() {
    let alice = @0xA;
    // let bob = @0xB;
    let scenario_val = test_scenario::begin(alice);
    let scenario = &mut scenario_val;
    {
      let ctx = test_scenario::ctx(scenario);
      nft_staking::init_for_testing(ctx);
    };

    let nft_a_id;
    // init reward coin
    test_scenario::next_tx(scenario, alice);
    {
      init_coin(NFT_STAKING_TESTS {}, scenario);
    };

    // create pool, mint nft
    test_scenario::next_tx(scenario, alice);
    let reward_coin = test_scenario::take_from_sender<Coin<NFT_STAKING_TESTS>>(scenario);
    std::debug::print<u64>(&coin::value<NFT_STAKING_TESTS>(&reward_coin));
    {
      let ctx = test_scenario::ctx(scenario);
      nft_staking::create_pool<NFT_STAKING_TESTS, NftA>(
        alice,
        reward_coin,
        1000000_000_000_000,
        1,
        10_000_000_000,
        1000_000_000_000,
        ctx
      );
      mint_nft_a(alice, scenario);
    };

    // stake nft
    test_scenario::next_tx(scenario, alice);
    {
      let poolInfo = test_scenario::take_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(scenario);
      let nftA = test_scenario::take_from_sender<NftA>(scenario);
      // save nft_a_id
      nft_a_id = object::id(&nftA);

      let ctx = test_scenario::ctx(scenario);

      let clock_obj = clock::create_for_testing(ctx);
      nft_staking::stake_nft<NFT_STAKING_TESTS, NftA>(
        &mut poolInfo,
        nftA,
        10_000_000_000,
        &clock_obj,
        ctx
      );
      test_scenario::return_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(poolInfo);
      clock::destroy_for_testing(clock_obj);
    };

    // check NFT stakeInfo, try claim reward
    test_scenario::next_tx(scenario, alice);
    {
      std::debug::print<String>(&string::utf8(b"after stake"));
      let pool_info = test_scenario::take_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(scenario);
      std::debug::print<PoolInfo<NFT_STAKING_TESTS, NftA>>(&pool_info);

      let user_info = ofield::borrow<address, UserInfo<NftA>>(nft_staking::get_pool_id(&pool_info), alice);
      std::debug::print<UserInfo<NftA>>(user_info);

      let ctx = test_scenario::ctx(scenario);
      let clock_obj = clock::create_for_testing(ctx);
      clock::increment_for_testing(&mut clock_obj, 3600 * 5); // increase 5 hours

      nft_staking::claim_reward<NFT_STAKING_TESTS, NftA>(&mut pool_info, &clock_obj, ctx);

      test_scenario::return_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(pool_info);
      clock::destroy_for_testing(clock_obj);
    };

    // check claimed status & unstake nft
    test_scenario::next_tx(scenario, alice);
    {
      std::debug::print<String>(&string::utf8(b"after claim"));
      let reward_coin = test_scenario::take_from_sender<Coin<NFT_STAKING_TESTS>>(scenario);
      std::debug::print<u64>(&coin::value<NFT_STAKING_TESTS>(&reward_coin));
      test_scenario::return_to_sender(scenario, reward_coin);

      let pool_info = test_scenario::take_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(scenario);
      std::debug::print<PoolInfo<NFT_STAKING_TESTS, NftA>>(&pool_info);

      let user_info = ofield::borrow<address, UserInfo<NftA>>(nft_staking::get_pool_id(&pool_info), alice);
      std::debug::print<UserInfo<NftA>>(user_info);

      // unstake
      let ctx = test_scenario::ctx(scenario);
      let clock_obj = clock::create_for_testing(ctx);
      clock::increment_for_testing(&mut clock_obj, 3600 * 5); // increase 5 hours
      clock::increment_for_testing(&mut clock_obj, 300); // increase 300 seconds

      nft_staking::unstake_nft<NFT_STAKING_TESTS, NftA>(
        &mut pool_info,
        nft_a_id,
        0,
        &clock_obj,
        ctx
      );

      clock::destroy_for_testing(clock_obj);
      test_scenario::return_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(pool_info);
    };

    // check unstaked status & claim remained rewards
    test_scenario::next_tx(scenario, alice);
    {
      std::debug::print<String>(&string::utf8(b"after unstake"));

      let pool_info = test_scenario::take_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(scenario);
      std::debug::print<PoolInfo<NFT_STAKING_TESTS, NftA>>(&pool_info);

      let user_info = ofield::borrow<address, UserInfo<NftA>>(nft_staking::get_pool_id(&pool_info), alice);
      std::debug::print<UserInfo<NftA>>(user_info);

      // unstake
      let ctx = test_scenario::ctx(scenario);
      let clock_obj = clock::create_for_testing(ctx);
      clock::increment_for_testing(&mut clock_obj, 3600 * 5); // increase 5 hours
      clock::increment_for_testing(&mut clock_obj, 300); // increase 300 seconds

      nft_staking::claim_reward<NFT_STAKING_TESTS, NftA>(&mut pool_info, &clock_obj, ctx);

      clock::destroy_for_testing(clock_obj);
      test_scenario::return_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(pool_info);
    };

    // admin tries withdraw reward
    test_scenario::next_tx(scenario, alice);
    {
      let pool_info = test_scenario::take_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(scenario);
      std::debug::print<PoolInfo<NFT_STAKING_TESTS, NftA>>(&pool_info);

      let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);

      let ctx = test_scenario::ctx(scenario);
      nft_staking::withdraw_reward<NFT_STAKING_TESTS, NftA>(
        &admin_cap, 
        &mut pool_info, 
        ctx
      );

      test_scenario::return_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(pool_info);
      test_scenario::return_to_sender(scenario, admin_cap);

    };

    // check withdrawn reward coins
    test_scenario::next_tx(scenario, alice);
    {
      std::debug::print<String>(&string::utf8(b"after withdraw"));
      let reward_coin = test_scenario::take_from_sender<Coin<NFT_STAKING_TESTS>>(scenario);
      std::debug::print<u64>(&coin::value<NFT_STAKING_TESTS>(&reward_coin));
      test_scenario::return_to_sender(scenario, reward_coin);

      let pool_info = test_scenario::take_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(scenario);
      std::debug::print<PoolInfo<NFT_STAKING_TESTS, NftA>>(&pool_info);

      test_scenario::return_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(pool_info);
    };
    test_scenario::end(scenario_val);
  }

  // admin tries change admin and withdraw reward

  #[test]
  //#[expected_failure(abort_code = nft_staking::EINVALID_ADMIN)]
  public fun test_admin_transfer_ownership_and_withdraw() {
    let alice = @0xA;
    let bob = @0xB;
    let scenario_val = test_scenario::begin(alice);
    let scenario = &mut scenario_val;
    {
      let ctx = test_scenario::ctx(scenario);
      nft_staking::init_for_testing(ctx);
    };

    // init reward coin
    test_scenario::next_tx(scenario, alice);
    {
      init_coin(NFT_STAKING_TESTS {}, scenario);
    };

    // create pool, mint nft
    test_scenario::next_tx(scenario, alice);
    let reward_coin = test_scenario::take_from_sender<Coin<NFT_STAKING_TESTS>>(scenario);
    std::debug::print<u64>(&coin::value<NFT_STAKING_TESTS>(&reward_coin));
    {
      let ctx = test_scenario::ctx(scenario);
      nft_staking::create_pool<NFT_STAKING_TESTS, NftA>(
        alice,
        reward_coin,
        1000000_000_000_000,
        1,
        10_000_000_000,
        1000_000_000_000,
        ctx
      );
    };

    test_scenario::next_tx(scenario, alice);
    {
      let pool_info = test_scenario::take_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(scenario);
      std::debug::print<PoolInfo<NFT_STAKING_TESTS, NftA>>(&pool_info);

      let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);

      let ctx = test_scenario::ctx(scenario);
      nft_staking::change_admin<NFT_STAKING_TESTS, NftA>(
        admin_cap, 
        bob,
        ctx
      );

      test_scenario::return_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(pool_info);  
    };
    
    // withdraw reward coin
    test_scenario::next_tx(scenario, bob);
    {
      let pool_info = test_scenario::take_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(scenario);
      std::debug::print<PoolInfo<NFT_STAKING_TESTS, NftA>>(&pool_info);

      let admin_cap = test_scenario::take_from_sender<AdminCap>(scenario);

      let ctx = test_scenario::ctx(scenario);
      nft_staking::withdraw_reward<NFT_STAKING_TESTS, NftA>(
        &admin_cap, 
        &mut pool_info, 
        ctx
      );

      test_scenario::return_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(pool_info);
      test_scenario::return_to_sender(scenario, admin_cap);

    };

    // check withdrawn reward coins
    test_scenario::next_tx(scenario, bob);
    {
      std::debug::print<String>(&string::utf8(b"after withdraw"));
      let reward_coin = test_scenario::take_from_sender<Coin<NFT_STAKING_TESTS>>(scenario);
      std::debug::print<u64>(&coin::value<NFT_STAKING_TESTS>(&reward_coin));
      test_scenario::return_to_sender(scenario, reward_coin);

      let pool_info = test_scenario::take_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(scenario);
      std::debug::print<PoolInfo<NFT_STAKING_TESTS, NftA>>(&pool_info);

      test_scenario::return_shared<PoolInfo<NFT_STAKING_TESTS, NftA>>(pool_info);
    };
    test_scenario::end(scenario_val);
  }


}