$ROOT = File.dirname(__FILE__)
$LOAD_PATH.unshift File.join($ROOT, 'lib')

require 'bundler'
Bundler.require

require_relative 'lib/voting_booth'
VotingBooth.run
