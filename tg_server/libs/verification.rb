require_relative "tx_generator.rb"
require_relative "ckb_interaction.rb"

def group_tx_input(tx)
  group = Hash.new()
  index = 0
  for input in tx.inputs
    validation = @api.get_live_cell(input.previous_output)
    return -1 if validation.status != "live"
    lock_args = validation.cell.output.lock.args
    if !group.keys.include?(lock_args)
      group[lock_args] = Array.new()
    end
    group[lock_args] << index
    index += 1
  end
  return group
end

def generate_msg_from_info(info, flag)
  if flag == "closing"
    num = 1
  elsif flag == "settlement"
    num = 2
  else
    puts "the flag is invalid."
    return false
  end

  counter = 0
  msg_signed = "0x"

  for output in info[:outputs]
    break if counter == num
    msg_signed += CKB::Serializers::OutputSerializer.new(output).serialize[2..]
    counter += 1
  end
  counter = 0
  for data in info[:outputs_data]
    break if counter == num
    msg_signed += data[2..]
    counter += 1
  end

  return msg_signed
end

def verify_info_sig(info, flag, pubkey, sig_index)

  # load signature
  info_witness = @tx_generator.parse_witness(info[:witnesses][0])
  info_witness_lock = @tx_generator.parse_witness_lock(info_witness.lock)
  signature = case sig_index
    when 0
      info_witness_lock[:sig_A]
    when 1
      info_witness_lock[:sig_B]
    end

  # generate the msg.
  msg_signed = generate_msg_from_info(info, flag)

  # add the length of witness.
  witness_len = (info[:witnesses][0].bytesize - 2) / 2
  witness_len = CKB::Utils.bin_to_hex([witness_len].pack("Q<"))[2..-1]

  # add the empty witness.
  empty_witness = @tx_generator.generate_empty_witness(info_witness_lock[:id], info_witness_lock[:flag],
                                                       info_witness_lock[:nounce])
  empty_witness = CKB::Serializers::WitnessArgsSerializer.from(empty_witness).serialize[2..-1]
  msg_signed = (msg_signed + witness_len + empty_witness).strip
  msg_signed = CKB::Blake2b.hexdigest(CKB::Utils.hex_to_bin(msg_signed))
  return verify_signature(msg_signed, signature, pubkey) ? true : false
end

def verify_fund_tx_sig(tx, pubkey)
  input_group = group_tx_input(tx)
  return false if input_group == -1

  first_index = input_group[pubkey][0]
  # include the content needed sign.
  blake2b = CKB::Blake2b.new
  blake2b.update(CKB::Utils.hex_to_bin(tx.hash))

  # include the first witness, I need to parse the witness!
  emptied_witness = case tx.witnesses[first_index]
    when CKB::Types::Witness
      tx.witnesses[first_index]
    else
      @tx_generator.parse_witness(tx.witnesses[first_index])
    end
  signature = emptied_witness.lock[2..]
  emptied_witness.lock = "0x#{"0" * 130}"
  emptied_witness_data_binary = CKB::Utils.hex_to_bin(CKB::Serializers::WitnessArgsSerializer.from(emptied_witness).serialize)
  emptied_witness_data_size = emptied_witness_data_binary.bytesize
  blake2b.update([emptied_witness_data_size].pack("Q<"))
  blake2b.update(emptied_witness_data_binary)

  #include the witness in the same group
  for index in input_group[pubkey][1..]
    witness = tx.witnesses[index]
    data_binary = case witness
      when CKB::Types::Witness
        CKB::Utils.hex_to_bin(CKB::Serializers::WitnessArgsSerializer.from(witness).serialize)
      else
        CKB::Utils.hex_to_bin(witness)
      end
    data_size = data_binary.bytesize
    blake2b.update([data_size].pack("Q<"))
    blake2b.update(data_binary)
  end

  # include other witness
  witnesses_len = tx.witnesses.length()
  input_len = tx.inputs.length()
  witness_no_input_index = (input_len..witnesses_len - 1).to_a
  for index in witness_no_input_index
    witness = tx.witnesses[index]
    data_binary = case witness
      when CKB::Types::Witness
        CKB::Utils.hex_to_bin(CKB::Serializers::WitnessArgsSerializer.from(witness).serialize)
      else
        CKB::Utils.hex_to_bin(witness)
      end
    data_size = data_binary.bytesize
    blake2b.update([data_size].pack("Q<"))
    blake2b.update(data_binary)
  end

  message = blake2b.hexdigest

  return verify_signature(message, signature, pubkey) ? true : false
end

def verify_signature(data, sig, pubkey)
  begin
    unrelated = MyECDSA.new

    signature_bin = CKB::Utils.hex_to_bin("0x" + sig[0..127])
    recid = CKB::Utils.hex_to_bin("0x" + sig[128..129]).unpack("C*")[0]

    sig_reverse = unrelated.ecdsa_recoverable_deserialize(signature_bin, recid)
    pubkey_reverse = unrelated.ecdsa_recover(CKB::Utils.hex_to_bin(data), sig_reverse, raw: true)
    pubser = Secp256k1::PublicKey.new(pubkey: pubkey_reverse).serialize
    pubkey_reverse = CKB::Utils.bin_to_hex(pubser)

    pubkey_verify = CKB::Key.blake160(pubkey_reverse)

    pubkey_verify = pubkey_verify.sub("0x", "")
    pubkey = pubkey.sub("0x", "")

    return pubkey_verify == pubkey ? true : false
  rescue Exception => e
    return false
  end
end

def verify_change(tx, input_cells, input_capacity, fee, pubkey)
  remote_change = 0

  for output in tx.outputs
    remote_change += output.capacity if pubkey == output.lock.args
  end

  local_change = get_total_capacity(input_cells) - CKB::Utils.byte_to_shannon(input_capacity) - fee

  return remote_change == local_change ? true : false
end

def verify_info_args(info1, info2)
  @logger.info("verify_info_args: begin to verify.")
  # parse the witness.
  prefix_len = 52
  witness_array1 = info1[:witnesses]
  witness_array2 = info2[:witnesses]

  # clear the witness to check the args are right.
  witness_array = Array.new()
  for witness1 in witness_array1
    witness1 = case witness1
      when CKB::Types::Witness
        witness1
      else
        @tx_generator.parse_witness(witness1)
      end
    witness1.lock[prefix_len..-1] = "00" * 130
    witness_array << witness1
  end
  witness_array1 = witness_array

  witness_array = Array.new()
  for witness2 in witness_array2
    witness2 = case witness2
      when CKB::Types::Witness
        witness2
      else
        @tx_generator.parse_witness(witness2)
      end
    witness2.lock[prefix_len..-1] = "00" * 130
    witness_array << witness2
  end

  @logger.info("verify_info_args: witness is clean.")

  witness_array2 = witness_array

  # serilize?
  witness_array1 = witness_array1.map { |witness| CKB::Serializers::WitnessArgsSerializer.from(witness).serialize }
  witness_array2 = witness_array2.map { |witness| CKB::Serializers::WitnessArgsSerializer.from(witness).serialize }
  # compare.
  return false if info1[:witnesses].length != info2[:witnesses].length ||
                  info1[:outputs].length != info2[:outputs].length ||
                  info1[:outputs_data].length != info2[:outputs_data].length

  @logger.info("verify_info_args: length is right!")
  for index in (0..witness_array1.length - 1)
    return false if witness_array1[index] != witness_array2[index]
  end
  @logger.info("verify_info_args: witnesses are right!")

  for index in (0..info1[:outputs].length - 1)
    return false if info1[:outputs][index].to_h != info2[:outputs][index].to_h
    return false if info1[:outputs_data][index] != info2[:outputs_data][index]
  end
  @logger.info("verify_info_args: outputs and outputs_data are right!")
  return true
end
