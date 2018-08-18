#!/usr/bin/env ruby
# WARNING: This uses the unstable v2 API so will probably break at some point

lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require 'rubygems'
require 'commander/import'
require 'rest-client'
require 'json'
require 'csv'
require 'yaml'
require 'qif'
require 'colorize'
require 'starling/export/version'

program :name, 'starling-export'
program :version, Starling::Export::VERSION
program :description, 'Generate QIF or CSV from Starling'

command :qif do |c|
  c.syntax = 'starling-export qif [options]'
  c.summary = ''
  c.description = ''
  c.option '--directory STRING', String, 'The directory to save this file'
  c.option '--access_token STRING', String, 'The access_token from Starling'
  c.option '--since STRING', String, 'The date (YYYY-MM-DD) to start exporting transactions from. Defaults to 2 weeks ago'
  c.action do |args, options|
    @access_token ||= options.access_token
    since = options.since ? Date.parse(options.since).to_time.strftime('%FT00:00:01.000Z') : (Time.now - (60*60*24*14)).to_date.strftime('%FT00:00:01.000Z')
    options.default directory: "#{File.dirname(__FILE__)}/exports"
    path = "#{options.directory}/starling-#{since}.qif"

    Qif::Writer.open(path, type = 'Bank', format = 'dd/mm/yyyy') do |qif|

      all_transactions = transactions_v2(since)
      total_count = all_transactions.size

      all_transactions.reverse.each_with_index do |transaction, index|
        amount = (transaction['amount']['minorUnits'].to_f / 100).abs.to_s.ljust(6, ' ')
        amount_with_color = transaction['direction'] == 'IN' ? amount.green : amount.red
        amount = "-#{amount}" if transaction['direction'] == 'OUT'

        puts "[#{(index + 1).to_s.rjust(total_count.to_s.length) }/#{total_count}] #{Date.parse(transaction['transactionTime']).to_s} - #{transaction['feedItemUid']} - #{amount_with_color}  "

        qif << Qif::Transaction.new(
          date: DateTime.parse(transaction['transactionTime']).to_date,
          amount: '%.2f' % amount,
          status: transaction['status'] == "SETTLED" ? 'c' : nil,
          memo: "#{transaction['reference']}",
          payee: transaction['counterPartyName'],
          number: set_number(transaction),
          category: map_category(transaction),
        )
      end
    end

    puts ""
    puts "Exported to #{path}"
  end
end

command :csv do |c|
  c.syntax = 'starling-export csv [options]'
  c.summary = ''
  c.description = ''
  c.option '--directory STRING', String, 'The directory to save this file'
  c.option '--access_token STRING', String, 'The access_token from Starling'
  c.option '--since STRING', String, 'The date (YYYY-MM-DD) to start exporting transactions from. Defaults to 2 weeks ago'
  c.action do |args, options|
    @access_token ||= options.access_token
    since = options.since ? Date.parse(options.since).to_time.strftime('%FT00:00:01.000Z') : (Time.now - (60*60*24*14)).to_date.strftime('%FT00:00:01.000Z')
    options.default directory: "#{File.dirname(__FILE__)}/exports"
    path = "#{options.directory}/starling-#{since}.csv"

    CSV.open(path, "wb") do |csv|
      csv << [:date, :description, :amount, :balance]

      all_transactions = transactions_v2(since)
      total_count = all_transactions.size

      all_transactions.reverse.each_with_index do |transaction, index|

        amount = (transaction['amount']['minorUnits'].to_f / 100).abs.to_s.ljust(6, ' ')
        amount_with_color = transaction['direction'] == 'IN' ? amount.green : amount.red
        amount = "-#{amount}" if transaction['direction'] == 'OUT'

        puts "[#{(index + 1).to_s.rjust(total_count.to_s.length) }/#{total_count}] #{Date.parse(transaction['transactionTime']).to_s} - #{transaction['feedItemUid']} - #{amount_with_color}  "

        csv << [
          DateTime.parse(transaction['transactionTime']).strftime("%d/%m/%y"),
          transaction['counterPartyName'],
          '%.2f' % amount,
          transaction['balance']
        ]
      end
    end

    puts ""
    puts "Exported to #{path}"
  end
end

command :balance do |c|
  c.syntax = 'starling-export balance [options]'
  c.summary = ''
  c.option '--access_token STRING', String, 'The access_token from Starling'
  c.action do |args, options|
    @access_token ||= options.access_token
    account_data = account_v2()
    #puts "Account Number: #{account_data['accountNumber']}"
    #puts "Sort Code: #{account_data['sortCode']}"
    puts "Balance: £#{balance_v2(account_data['accountUid'])}"
  end
end

def perform_request(path)
  url = "https://api.starlingbank.com/api/#{path}"
  JSON.parse(RestClient.get(url, {:Authorization => "Bearer #{@access_token}"}))
end

def account_v2
  perform_request("v2/accounts")
end

def balance_v2(acc_id = nil)
  unless acc_id
    account = account_v2()['accounts'].first
    acc_id = account['accountUid']
  end
  perform_request("v2/accounts/#{acc_id}/balance")['availableToSpend']['minorUnits'].to_f / 100
end

def transactions_v2(from)
  account = account_v2()['accounts'].first
  acc_id = account['accountUid']
  cat_id = account['defaultCategory']

  perform_request("v2/feed/account/#{acc_id}/category/#{cat_id}/?changesSince=#{from}")['feedItems']
end

def set_number(txn)
  return 'Online' if txn['sourceSubType'] && txn['sourceSubType'] == 'ONLINE'
  return 'ATM' if txn['sourceSubType'] && txn['sourceSubType'] == 'ATM'
  return 'Transfer' if txn['source'] == 'INTERNAL_TRANSFER'
  return 'Deposit' if txn['direction'] == 'IN'
  return 'POS'
end

def map_category(txn)
    return nil unless txn['spendingCategory']
    cat = txn['spendingCategory']

    category_map = {
      'BILLS_AND_SERVICES'  => nil,
      'CHARITY'             => 'Charity',
      'EATING_OUT'          => 'Dining:Restaurants',
      'ENTERTAINMENT'       => 'Entertainment',
      'EXPENSES'            => 'Work Expenses',
      'FAMILY'              => 'Household',
      'GENERAL'             => nil,
      'GIFTS'               => 'Gifts',
      'GROCERIES'           => 'Groceries',
      'HOME'                => 'Household:Home Maintenance',
      'INCOME'              => nil,
      'SAVING'              => nil,
      'SHOPPING'            => 'Clothing',
      'HOLIDAYS'            => 'Travel',
      'PAYMENTS'            => nil,
      'PETS'                => nil,
      'TRANSPORT'           => 'Travel',
      'LIFESTYLE'           => nil,
    }

    return category_map[cat] if category_map.include?(cat)
    return 'ATM' if txn['sourceSubType'] && txn['sourceSubType'] == 'ATM'
    return 'Interest Received' if txn['source'] == 'INTEREST_PAYMENT'

    nil
  end
