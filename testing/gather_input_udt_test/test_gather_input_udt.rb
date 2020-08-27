require_relative "../miscellaneous/libs/gpctest.rb"
require "minitest/autorun"
require "mongo"
require "bigdecimal"

Mongo::Logger.logger.level = Logger::FATAL

class Gather_input_udt < Minitest::Test
  def gather_input(file_name)
    @path_to_file= __dir__ + "/../miscellaneous/files/"
@logger = Logger.new( @path_to_file+ "gpc.log")
    @client = Mongo::Client.new(["127.0.0.1:27017"], :database => "GPC")
    @db = @client.database
    flag = "udt"
    begin
      data_raw = File.read(__dir__ + "/" + file_name)
      data_json = JSON.parse(data_raw, symbolize_names: true)

      container_min = data_json[:container_min].to_i
      funding_fee_A = data_json[:funding_fee_A].to_i
      funding_fee_B = data_json[:funding_fee_B].to_i
      funding_amount_A = data_json[:funding_amount_A].to_i
      funding_amount_B = data_json[:funding_amount_B].to_i

      # # prepare the test
      tests = Gpctest.new("test")
      tests.setup()

      investment_A = funding_amount_A
      investment_B = funding_amount_B
      expect = data_json[:expect_info]
      @monitor_A, @monitor_B = tests.check_investment_fee(investment_A, investment_B, funding_fee_A, funding_fee_B, expect, flag)

      result_json = tests.load_json_file(__dir__ + "/../miscellaneous/files/result.json").to_json
      assert_match(expect[1..-2], result_json, "#{expect}")
    rescue => exception
      raise exception
    ensure
      tests.close_all_thread(@monitor_A, @monitor_B, @db)
    end
  end

  # receiver

  def test_receiver_gather_insufficient_1_stage()
    gather_input("Receiver_gather_insufficient_1_stage.json")
  end

  def test_receiver_gather_insufficient_2_stage()
    gather_input("Receiver_gather_insufficient_2_stage.json")
  end

  def test_receiver_gather_success_1_stage()
    gather_input("Receiver_gather_success_1_stage.json")
  end

  def test_receiver_gather_success_2_stage()
    gather_input("Receiver_gather_success_2_stage.json")
  end

  # sender

  def test_sender_gather_insufficient_1_stage()
    gather_input("Sender_gather_insufficient_1_stage.json")
  end

  def test_sender_gather_insufficient_2_stage()
    gather_input("Sender_gather_insufficient_2_stage.json")
  end

  def test_sender_gather_success_1_stage()
    gather_input("Sender_gather_success_1_stage.json")
  end

  def test_sender_gather_success_2_stage()
    gather_input("Sender_gather_success_2_stage.json")
  end
end
