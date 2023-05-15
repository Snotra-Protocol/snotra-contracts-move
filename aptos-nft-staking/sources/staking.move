///This is the contract for the NFT staking on APTOS
module staking_addr::staking {
    use std::bcs::to_bytes;
    use std::error;
    use std::signer;
    use std::string::{String, append};
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::account::SignerCapability;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::timestamp;
    use aptos_std::ed25519;
    use aptos_std::event::{Self, EventHandle};
    use aptos_std::string_utils::to_string;
    use aptos_std::table::{Self, Table};
    use aptos_std::type_info;
    use aptos_token::token::{Self, Token};

    const EINVALID_OWNER: u64 = 1;
    const EESCROW_ALREADY_INITED: u64 = 2;
    const EINVALID_NFTID_OR_INDEX: u64 = 3;
    const EINVALID_TIME: u64 = 4;
    const EINVALID_INDEX: u64 = 5;
    const EEXCEED_MAX_DAILY_REWARD: u64 = 6;
    const EINVALID_ADMIN: u64 = 7;
    const EINVALID_DAILY_REWARD: u64 = 8;
    const EINVALID_SIGNATURE: u64 = 9;
    const ESTILL_LOCKED: u64 = 10;
    const EPOOL_ENDED: u64 = 11;
    const EINSUFFICIENT_FEE_AMOUNT: u64 = 12;
    const EINVALID_AMOUNT: u64 = 13;
    const ENO_NO_STAKING: u64 = 14;
    const ENO_STAKING_EXISTS: u64 = 15;
    const ENO_NO_COLLECTION: u64 = 16;
    const ENOT_ENOUGH_LENGTH: u64 = 17;
    const EAPP_NOT_INITIALIZED: u64 = 18;

    const SEED: vector<u8> = b"SEED";
    const SECONDS_PER_DAY: u64 = 24 * 60 * 60;

    struct PlatformInfo has key {
        admin_address: address,
        treasury: address,
        admin_cap: SignerCapability,
        platform_fee: coin::Coin<AptosCoin>,
        sig_verify_pk: vector<u8>,
        pool_lists: Table<u64, SignerCapability>
    }

    struct NftStakeInfo has store {
        pool_id: u64,
        nft: Token,
        stake_time: u64,
        daily_reward: u64,
        last_reward_claim_time: u64,
        pending_reward: u64
    }

    struct UserInfo has key {
        user_address: address,
        nfts: vector<NftStakeInfo>,
    }

    struct PoolInfo<phantom RewardCoin> has key {
        pool_id: u64,
        creator_address: address,
        collection_name: String,
        reward_coin: coin::Coin<RewardCoin>,
        daily_reward_per_nft: u64,
        max_daily_reward_per_nft: u64,
        is_rarity: u8,
        creation_time: u64,
        lock_duration: u64,
        stake_nonce: u64,
        total_staked_count: u64,
        total_claimed_reward: u64
    }

    struct MyEvents has key {
        pool_created_event: EventHandle<PoolCreated>,
        nft_staked_event: EventHandle<NftStaked>,
        nft_unstaked_event: EventHandle<NftUnStaked>,
        claimed_reward_event: EventHandle<ClaimedReward>
    }

    struct PoolCreated has store, drop {
        pool_id: u64,
        creator: address,
        nft_type: String,
        reward_coin_type: String,
        is_rarity: u8,
        creation_time: u64,
        lock_duration: u64,
        daily_reward_per_nft: u64,
        max_daily_reward_per_nft: u64,
        initial_reward_amt: u64,
    }

    struct NftStaked has store, drop {
        nft_id: String,
        pool_id: u64,
        owner: address,
        nft_type: String,
        reward_coin_type: String,
        daily_reward: u64,
    }

    struct NftUnStaked has store, drop {
        nft_id: String,
        pool_id: u64,
        owner: address,
        nft_type: String,
        reward_coin_type: String
    }

    struct ClaimedReward has store, drop {
        owner: address,
        pool_id: u64,
        claimed_amount: u64,
    }

    fun init(
        initializer: &signer,
        admin_address: address,
        treasury: address
    ) {
        let initializer_addr = signer::address_of(initializer);
        assert!(initializer_addr == @staking_addr, error::permission_denied(EINVALID_OWNER));

        let (resource_signer, resource_cap) = account::create_resource_account(initializer, SEED);

        move_to(&resource_signer, PlatformInfo {
            admin_address: admin_address,
            treasury: treasury,
            admin_cap: resource_cap,
            sig_verify_pk: vector::empty<u8>(),
            platform_fee: coin::zero<AptosCoin>(),
            pool_lists: table::new<u64, SignerCapability>()
        });

        move_to(&resource_signer, MyEvents {
            pool_created_event: account::new_event_handle<PoolCreated>(&resource_signer),
            nft_staked_event: account::new_event_handle<NftStaked>(&resource_signer),
            nft_unstaked_event: account::new_event_handle<NftUnStaked>(&resource_signer),
            claimed_reward_event: account::new_event_handle<ClaimedReward>(&resource_signer),
        });
    }

    public fun verify_signature(
        main_value: vector<u64>,
        nonce_value: u64,
        verify_pk: vector<u8>,
        msg: vector<u8>
    ): bool {
        if (msg == vector::empty<u8>()) {
            return true
        };

        let sign_data = std::bcs::to_bytes(&main_value);
        let nonce_bytes = std::bcs::to_bytes(&nonce_value);
        vector::append(&mut sign_data, nonce_bytes);

        let signature = ed25519::new_signature_from_bytes(sign_data);
        let validated_public_key = std::option::extract(&mut ed25519::new_validated_public_key_from_bytes(verify_pk));
        let unvalidated_public_key = ed25519::public_key_to_unvalidated(&validated_public_key);

        let verify = ed25519::signature_verify_strict(
            &signature, 
            &unvalidated_public_key, 
            msg
        );
        verify
    }

    public fun create_pool<RewardCoin>(
        admin: &signer,
        creator: address,
        collection_name: String,
        initial_reward_amt: u64,
        is_rarity: u8,
        lock_duration: u64,
        daily_reward_per_nft: u64,
        max_daily_reward_per_nft: u64,
    ) : u64 acquires PlatformInfo, PoolInfo, MyEvents {
        let platform_address = account::create_resource_address(&@staking_addr, SEED);
        assert!(exists<PlatformInfo>(platform_address), error::not_found(EAPP_NOT_INITIALIZED));
        let platform_info = borrow_global_mut<PlatformInfo>(platform_address);

        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == platform_info.admin_address, error::permission_denied(EINVALID_ADMIN));

        let pool_lists = &mut platform_info.pool_lists;
        let seed = collection_name;
        append(&mut seed, to_string(&creator));
        let (resource_signer, resource_cap) = account::create_resource_account(admin, to_bytes(&seed));
        let resource_signer_address = signer::address_of(&resource_signer);

        let id = account::get_sequence_number(admin_addr);
        let cur_time = timestamp::now_seconds();

        if (!exists<PoolInfo<RewardCoin>>(resource_signer_address)) {
            move_to(&resource_signer, PoolInfo {
                pool_id: id,
                creator_address: creator,
                collection_name: collection_name,
                reward_coin: coin::zero<RewardCoin>(),
                daily_reward_per_nft: daily_reward_per_nft,
                max_daily_reward_per_nft: max_daily_reward_per_nft,
                is_rarity: is_rarity,
                creation_time: cur_time,
                lock_duration: lock_duration,
                stake_nonce: 0,
                total_staked_count: 0,
                total_claimed_reward: 0
            })
        };

        let pool = borrow_global_mut<PoolInfo<RewardCoin>>(resource_signer_address);
        let deposit_reward_balance = coin::balance<RewardCoin>(admin_addr);

        assert!(deposit_reward_balance > initial_reward_amt, error::invalid_argument(EINVALID_AMOUNT));

        let withdraw_money = coin::withdraw<RewardCoin>(admin, initial_reward_amt);
        coin::merge<RewardCoin>(&mut pool.reward_coin, withdraw_money);

        let my_events = borrow_global_mut<MyEvents>(platform_address);
        event::emit_event(
            &mut my_events.pool_created_event,
            PoolCreated {
                pool_id: id,
                creator: admin_addr,
                nft_type: collection_name,
                reward_coin_type: type_info::type_name<RewardCoin>(),
                is_rarity: is_rarity,
                creation_time: cur_time,
                lock_duration: lock_duration,
                daily_reward_per_nft: daily_reward_per_nft,
                max_daily_reward_per_nft: max_daily_reward_per_nft,
                initial_reward_amt: initial_reward_amt,
            }
        );

        if (!table::contains(pool_lists, id)) {
            table::add(pool_lists, id, resource_cap);
        };
        return id
    }

    public entry fun batch_stake_nft<RewardCoin>(
        staker: &signer,
        creators: vector<address>,
        collection_names: vector<String>,
        token_names: vector<String>,
        property_versions: vector<u64>,
        pool_id: u64,
        daily_rewards: vector<u64>,
        daily_reward_signature: vector<u8>,
        stake_fee_amounts: vector<u64>,
        stake_fee_amount_signature: vector<u8>
    ) acquires PlatformInfo, PoolInfo, UserInfo, MyEvents {
        let length_creators = vector::length(&creators);
        let length_collections = vector::length(&collection_names);
        let length_token_names = vector::length(&token_names);
        let length_properties = vector::length(&property_versions);
        let length_daily_rewards = vector::length(&daily_rewards);

        assert!(length_collections == length_creators
                && length_creators == length_token_names
                && length_token_names == length_properties
                && length_properties == length_daily_rewards, error::invalid_argument(ENOT_ENOUGH_LENGTH));
        
        let sender = signer::address_of(staker);
        let platform_address = account::create_resource_address(&@staking_addr, SEED);
        let platform_info = borrow_global_mut<PlatformInfo>(platform_address);

        let pool_cap = table::borrow(&platform_info.pool_lists, pool_id);
        let pool_signer = &account::create_signer_with_capability(pool_cap);
        let pool_signer_address = signer::address_of(pool_signer);
        let pool = borrow_global_mut<PoolInfo<RewardCoin>>(pool_signer_address);

        if (!exists<UserInfo>(sender)) {
            move_to(staker, UserInfo {
                user_address: sender,
                nfts: vector::empty<NftStakeInfo>()
            })
        };

        let user = borrow_global_mut<UserInfo>(sender);

        let my_events = borrow_global_mut<MyEvents>(platform_address);
        let stake_fee_amount = vector::pop_back(&mut stake_fee_amounts);

        assert!(verify_signature(daily_rewards, pool.stake_nonce, platform_info.sig_verify_pk, daily_reward_signature) == true, error::invalid_argument(EINVALID_SIGNATURE));
        assert!(verify_signature(stake_fee_amounts, pool.stake_nonce, platform_info.sig_verify_pk, stake_fee_amount_signature) == true, error::invalid_argument(EINVALID_SIGNATURE));

        if (stake_fee_amount > 0) {
            let apt_balance = coin::balance<AptosCoin>(sender);
            assert!(apt_balance > stake_fee_amount, error::invalid_argument(EINVALID_AMOUNT));
            let withdraw_money = coin::withdraw<AptosCoin>(staker, stake_fee_amount);
            coin::merge<AptosCoin>(&mut platform_info.platform_fee, withdraw_money);
        };

        let i = length_token_names;

        while (i > 0){
            let creator = vector::pop_back(&mut creators);
            let collection_name = vector::pop_back(&mut collection_names);
            let token_name = vector::pop_back(&mut token_names);
            let property_version = vector::pop_back(&mut property_versions);
            let nft_id = token::create_token_id_raw(creator, collection_name, token_name, property_version);
            let daily_reward = vector::pop_back(&mut daily_rewards);

            assert!(token::check_collection_exists(sender, collection_name), error::not_found(ENO_NO_COLLECTION));

            let cur_time = timestamp::now_seconds();
            if (pool.lock_duration > 0) {
                assert!(pool.creation_time + pool.lock_duration > cur_time, error::invalid_state(EPOOL_ENDED));
            };

            assert!(daily_reward <= pool.max_daily_reward_per_nft, error::invalid_state(EEXCEED_MAX_DAILY_REWARD));

            if (pool.is_rarity == 0) {
                assert!(daily_reward == pool.daily_reward_per_nft, error::invalid_state(EINVALID_DAILY_REWARD));
            };

            let token = token::withdraw_token(staker, nft_id, 1);
            vector::push_back(&mut user.nfts, NftStakeInfo {
                pool_id: pool_id,
                nft: token,
                stake_time: cur_time,
                daily_reward: daily_reward,
                last_reward_claim_time: cur_time,
                pending_reward: 0
            });

            event::emit_event(
                &mut my_events.nft_staked_event,
                NftStaked {
                    nft_id: to_string(&nft_id),
                    pool_id: pool_id,
                    owner: sender,
                    nft_type: collection_name,
                    reward_coin_type: type_info::type_name<RewardCoin>(),
                    daily_reward: daily_reward,
                }
            );                               

            pool.total_staked_count = pool.total_staked_count + 1;
            pool.stake_nonce = pool.stake_nonce + 1;
            i = i - 1;
        }
	}

    public entry fun batch_unstake_nft<RewardCoin>(
        staker: &signer,
        creators: vector<address>,
        collection_names: vector<String>,
        token_names: vector<String>,
        property_versions: vector<u64>,
        pool_id: u64,
        stake_fee_amounts: vector<u64>,
        stake_fee_amount_signature: vector<u8>
    ) acquires PlatformInfo, PoolInfo, UserInfo, MyEvents {
        let length_creators = vector::length(&creators);
        let length_collections = vector::length(&collection_names);
        let length_token_names = vector::length(&token_names);
        let length_properties = vector::length(&property_versions);

        assert!(length_collections == length_creators
                && length_creators == length_token_names
                && length_token_names == length_properties, error::invalid_argument(ENOT_ENOUGH_LENGTH));

        let sender = signer::address_of(staker);
        let platform_address = account::create_resource_address(&@staking_addr, SEED);
        let platform_info = borrow_global_mut<PlatformInfo>(platform_address);
        
        let pool_cap = table::borrow(&platform_info.pool_lists, pool_id);
        let pool_signer = &account::create_signer_with_capability(pool_cap);
        let pool_signer_address = signer::address_of(pool_signer);
        let pool = borrow_global_mut<PoolInfo<RewardCoin>>(pool_signer_address);
        let user = borrow_global_mut<UserInfo>(sender);     
        let my_events = borrow_global_mut<MyEvents>(platform_address);          
        let stake_fee_amount = vector::pop_back(&mut stake_fee_amounts);

        assert!(verify_signature(stake_fee_amounts, pool.stake_nonce, platform_info.sig_verify_pk, stake_fee_amount_signature) == true, error::invalid_argument(EINVALID_SIGNATURE));
        
        if (stake_fee_amount > 0) {
            let apt_balance = coin::balance<AptosCoin>(sender);
            assert!(apt_balance > stake_fee_amount, error::invalid_argument(EINVALID_AMOUNT));
            let fee_coin = coin::withdraw<AptosCoin>(staker, stake_fee_amount);
            coin::merge<AptosCoin>(&mut platform_info.platform_fee, fee_coin);
        };

        let i = length_token_names;

        while (i > 0){
            let creator = vector::pop_back(&mut creators);
            let collection_name = vector::pop_back(&mut collection_names);
            let token_name = vector::pop_back(&mut token_names);
            let property_version = vector::pop_back(&mut property_versions);
            let nft_id = token::create_token_id_raw(creator, collection_name, token_name, property_version);

            let cur_time = timestamp::now_seconds();

            let pool_end_time = 0;
            if (pool.lock_duration > 0) {
                pool_end_time = pool.creation_time + pool.lock_duration;
                assert!(pool_end_time <= cur_time, error::invalid_state(ESTILL_LOCKED));
            };

            let j = vector::length(&user.nfts);   
            while (j > 0) {
                let nft_info_to_unstake = vector::borrow_mut<NftStakeInfo>(&mut user.nfts, j - 1);
                let nft_id_to_unstake = token::token_id(&nft_info_to_unstake.nft);

                if (nft_id_to_unstake == &nft_id) {
                    let nft_stake_time = nft_info_to_unstake.stake_time;
                    let nft_stake_daily_reward = nft_info_to_unstake.daily_reward;
                    let reward = get_reward(nft_stake_time, nft_stake_daily_reward, nft_info_to_unstake.last_reward_claim_time, cur_time, pool_end_time);
                    nft_info_to_unstake.pending_reward = nft_info_to_unstake.pending_reward + reward;
                    
                    let nft_to_unstake = vector::swap_remove<NftStakeInfo>(&mut user.nfts, j - 1);
                    let NftStakeInfo { pool_id: _, nft, stake_time: _, daily_reward: _, last_reward_claim_time: _, pending_reward: _ } = nft_to_unstake;
                    token::deposit_token(staker, nft);
                };

                j = j - 1;       
            };

            event::emit_event(
                &mut my_events.nft_unstaked_event,
                NftUnStaked {
                    nft_id: to_string(&nft_id),
                    pool_id: pool_id,
                    owner: sender,
                    nft_type: collection_name,
                    reward_coin_type: type_info::type_name<RewardCoin>(),
                }
            );

            pool.total_staked_count = pool.total_staked_count - 1;
            pool.stake_nonce = pool.stake_nonce + 1;              
            i = i - 1;
        }
	}

    fun get_reward(
        nft_stake_time: u64,
        nft_stake_daily_reward: u64,
        last_reward_claim_time: u64,
        current_time: u64,
        pool_end_time: u64
    ) : u64 {
        let base_time = current_time;

        if (pool_end_time > 0 && current_time > pool_end_time)
        base_time = pool_end_time;

        assert!(nft_stake_time <= base_time, error::invalid_state(EINVALID_TIME));

        if (last_reward_claim_time > base_time) return 0;

        let calculated_reward: u64;


        if (nft_stake_time < last_reward_claim_time) {
            let duration = base_time - last_reward_claim_time;
            calculated_reward = duration * nft_stake_daily_reward / SECONDS_PER_DAY;
        } else {
            let duration = base_time - nft_stake_time;
            calculated_reward = duration * nft_stake_daily_reward / SECONDS_PER_DAY;
        };

        calculated_reward
    }

    public fun calculate_rewards<RewardCoin>(
        staker: &signer,
        pool_id: u64
    ) : u64 acquires PlatformInfo, PoolInfo, UserInfo {
        let sender = signer::address_of(staker);
        let platform_address = account::create_resource_address(&@staking_addr, SEED);
        let platform_info = borrow_global_mut<PlatformInfo>(platform_address);

        let pool_cap = table::borrow(&platform_info.pool_lists, pool_id);
        let pool_signer = &account::create_signer_with_capability(pool_cap);
        let pool_signer_address = signer::address_of(pool_signer);
        let pool = borrow_global_mut<PoolInfo<RewardCoin>>(pool_signer_address);
        let user = borrow_global_mut<UserInfo>(sender);

        let cur_time = timestamp::now_seconds();

        let nft_count = vector::length<NftStakeInfo>(&user.nfts);
        let index = 0;
        let reward_sum = 0;

        let pool_end_time: u64 = 0;
        if (pool.lock_duration > 0) {
            pool_end_time = pool.creation_time + pool.lock_duration;
        };

        while (index < nft_count) {
            let nft = vector::borrow<NftStakeInfo>(&user.nfts, index);
            if (nft.pool_id == pool_id) {
                let nft_stake_time = nft.stake_time;
                let nft_stake_daily_reward = nft.daily_reward;
                let last_reward_claim_time = nft.last_reward_claim_time;
                reward_sum = reward_sum + get_reward(nft_stake_time, nft_stake_daily_reward, last_reward_claim_time, cur_time, pool_end_time);
            };
            index = index + 1;
        };

        reward_sum
    }

    public entry fun claim_reward<RewardCoin>(
        staker: &signer,
        collection_name: String,
        pool_id: u64
    ) acquires PlatformInfo, PoolInfo, UserInfo, MyEvents {
        let reward_sum = calculate_rewards<RewardCoin>(staker, pool_id);

        let sender = signer::address_of(staker);
        let platform_address = account::create_resource_address(&@staking_addr, SEED);
        let platform_info = borrow_global_mut<PlatformInfo>(platform_address);

        let pool_cap = table::borrow(&platform_info.pool_lists, pool_id);
        let pool_signer = &account::create_signer_with_capability(pool_cap);
        let pool_signer_address = signer::address_of(pool_signer);
        let pool = borrow_global_mut<PoolInfo<RewardCoin>>(pool_signer_address);

        assert!(token::check_collection_exists(sender, collection_name), error::not_found(ENO_NO_COLLECTION));

        let user = borrow_global_mut<UserInfo>(sender);
        let cur_time = timestamp::now_seconds();

        let total_reward_amount = coin::value<RewardCoin>(&pool.reward_coin);
        if (reward_sum > total_reward_amount) reward_sum = total_reward_amount;
       
        let reward_to_claim = coin::extract<RewardCoin>(&mut pool.reward_coin, reward_sum);
        coin::deposit<RewardCoin>(sender, reward_to_claim);

        let nft_count = vector::length<NftStakeInfo>(&user.nfts);
        while (nft_count > 0) {
            let nft = vector::borrow_mut<NftStakeInfo>(&mut user.nfts, nft_count - 1);
            if (nft.pool_id == pool_id) {
                nft.pending_reward = 0;
                nft.last_reward_claim_time = cur_time;
            };
            nft_count = nft_count - 1;
        };

        pool.total_claimed_reward = pool.total_claimed_reward + reward_sum;
        
        let my_events = borrow_global_mut<MyEvents>(platform_address);
        event::emit_event(
            &mut my_events.claimed_reward_event,
            ClaimedReward {
                owner: sender,
                pool_id: pool_id,
                claimed_amount: reward_sum
            }
        );
    }

    public entry fun set_treasury(
        admin: &signer,
        new_treasury: address
    ) acquires PlatformInfo {      
        let admin_address = signer::address_of(admin);
        let platform_address = account::create_resource_address(&@staking_addr, SEED);
        let platform_info = borrow_global_mut<PlatformInfo>(platform_address);

        assert!(platform_info.admin_address == admin_address, error::permission_denied(EINVALID_ADMIN));
        platform_info.treasury = new_treasury;
    }

    public entry fun change_admin(
        admin: &signer,
        new_admin_address: address
    ) acquires PlatformInfo {   
        let admin_address = signer::address_of(admin);
        let platform_address = account::create_resource_address(&@staking_addr, SEED);
        let platform_info = borrow_global_mut<PlatformInfo>(platform_address);

        assert!(platform_info.admin_address == admin_address, error::permission_denied(EINVALID_ADMIN));
        platform_info.admin_address = new_admin_address;
    }

    public entry fun change_verify_pk(
        admin: &signer,
        new_verify_pk: vector<u8>
    ) acquires PlatformInfo {
        let admin_address = signer::address_of(admin);
        let platform_address = account::create_resource_address(&@staking_addr, SEED);
        let platform_info = borrow_global_mut<PlatformInfo>(platform_address);

        assert!(platform_info.admin_address == admin_address, error::permission_denied(EINVALID_ADMIN));
        platform_info.sig_verify_pk = new_verify_pk;
    }

    public entry fun withdraw_reward<RewardCoin>(
        admin: &signer,
        pool_id: u64
    ) acquires PlatformInfo, PoolInfo {
        let admin_address = signer::address_of(admin);
        let platform_address = account::create_resource_address(&@staking_addr, SEED);
        let platform_info = borrow_global_mut<PlatformInfo>(platform_address);

        assert!(platform_info.admin_address == admin_address, error::permission_denied(EINVALID_ADMIN));
        let pool_cap = table::borrow(&platform_info.pool_lists, pool_id);
        let pool_signer = &account::create_signer_with_capability(pool_cap);
        let pool_signer_address = signer::address_of(pool_signer);
        let pool = borrow_global_mut<PoolInfo<RewardCoin>>(pool_signer_address);

        let total_reward_amount = coin::value<RewardCoin>(&pool.reward_coin);
        let reward_to_withdraw = coin::extract<RewardCoin>(&mut pool.reward_coin, total_reward_amount);
        coin::deposit<RewardCoin>(admin_address, reward_to_withdraw);
    }

    public entry fun withdraw_platform_fee(
        admin: &signer,
    ) acquires PlatformInfo {
        let admin_address = signer::address_of(admin);
        let platform_address = account::create_resource_address(&@staking_addr, SEED);
        let platform_info = borrow_global_mut<PlatformInfo>(platform_address);

        assert!(platform_info.admin_address == admin_address, error::permission_denied(EINVALID_ADMIN));
        let accumulated_fee_amount = coin::value<AptosCoin>(&platform_info.platform_fee);
        let fee_to_withdraw = coin::extract<AptosCoin>(&mut platform_info.platform_fee, accumulated_fee_amount);
        coin::deposit<AptosCoin>(admin_address, fee_to_withdraw);
    }

    #[test_only]
    use std::debug;
    #[test_only] 
    use std::string;
    #[test_only]
    use aptos_framework::aptos_account;
    #[test_only]
    use aptos_framework::managed_coin;

    #[test_only]
    struct FakeMeeCoin {
    }

    #[test_only]
    public fun initialize<CoinType>(
        authority: &signer
    ) {
        let authority_addr = signer::address_of(authority);

        init(authority, authority_addr, authority_addr);

        if (!coin::is_coin_initialized<CoinType>()) {
            managed_coin::initialize<CoinType>(authority, b"FakeCoinX", b"CoinX", 6, false);
        };

        if (!account::exists_at(authority_addr)) {
            aptos_account::create_account(authority_addr);
        };

        if (!coin::is_account_registered<CoinType>(authority_addr)) {
            coin::register<CoinType>(authority);
        };

        managed_coin::mint<CoinType>(authority, authority_addr, 10000); 

        assert!(coin::balance<CoinType>(authority_addr) == 10000, 1);
    }

    #[test(aptos_framework = @0x1, alice = @0xa11ce, owner = @staking_addr)]
    public entry fun e2e_test(
        aptos_framework: &signer,
        alice: signer,
        owner: signer
    ) acquires PlatformInfo, PoolInfo, UserInfo, MyEvents {
        let alice_address = signer::address_of(&alice);
                timestamp::set_time_has_started_for_testing(aptos_framework);

        initialize<FakeMeeCoin>(&owner);
        let pool_id_1 = create_pool<FakeMeeCoin>(&owner, alice_address, string::utf8(b"AAA"), 10u64, 0u8, 0u64, 1u64, 1u64);
        debug::print<string::String>(&string::utf8(b"The pool of AAA collection was created by owner!"));
        debug::print<u64>(&pool_id_1);

        let addresses_1 = vector<address>[alice_address];
        let collections_1 = vector<String>[string::utf8(b"Hello, World")];
        let token_names_1 = vector<String>[string::utf8(b"Token")];
        let property_versions_1 = vector<u64>[0];
        let daily_rewards_1 = vector<u64>[1];
        let stake_fee_amounts_1 = vector<u64>[0];

        account::create_account_for_test(alice_address);
        token::create_collection_and_token(
            &alice,
            1,
            2,
            1,
            vector<String>[],
            vector<vector<u8>>[],
            vector<String>[],
            vector<bool>[false, false, false],
            vector<bool>[false, false, false, false, false],
        );
        batch_stake_nft<FakeMeeCoin>(&alice, addresses_1, collections_1, token_names_1, property_versions_1, 0, daily_rewards_1, vector::empty<u8>(), stake_fee_amounts_1, vector::empty<u8>());
        debug::print<string::String>(&string::utf8(b"Alice staked one of her AAA NFT collection in the 1st pool!"));

        batch_unstake_nft<FakeMeeCoin>(&alice, addresses_1, collections_1, token_names_1, property_versions_1, 0, stake_fee_amounts_1, vector::empty<u8>());
        debug::print<string::String>(&string::utf8(b"Alice unstaked her AAA NFT in the 1st pool!"));        

        if (!coin::is_account_registered<FakeMeeCoin>(alice_address)) {
            coin::register<FakeMeeCoin>(&alice);
        };
        claim_reward<FakeMeeCoin>(&alice, string::utf8(b"Hello, World"), 0);
        debug::print<string::String>(&string::utf8(b"Alice claimed her reward in the 1st pool!"));

        withdraw_reward<FakeMeeCoin>(&owner, 0);
        debug::print<string::String>(&string::utf8(b"Owner withdrew the remaining reward in the 1st pool!"));        

        withdraw_platform_fee(&owner);
        debug::print<string::String>(&string::utf8(b"Owner withdrew the fee!"));
    }
}