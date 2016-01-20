require 'rubygems'
require 'active_record'
require 'yaml'
require 'logger'
require 'curb'
require 'nokogiri'
require 'open-uri'
require 'faraday'

#>======================Init=========================
ENV['RACK_ENV'] ||= "development"
dbconfig = YAML::load(File.open('database.yml'))
ActiveRecord::Base.establish_connection(dbconfig["panda_production"])
ActiveRecord::Base.logger = Logger.new(File.open('database.log', 'a'))
$err = Logger.new(File.open('err.log', 'a'))
$bad = Logger.new(File.open('bad.log', 'a'))
#<======================Init=======================

#>======================Models=======================
class PhoneSegment < ActiveRecord::Base
  has_one :failed_phone_segment, foreign_key: :phone_seg, primary_key: :phone_seg
  after_save :remove_failed_record
  def remove_failed_record
    self.failed_phone_segment.destroy
  end
end

class FailedPhoneSegment < ActiveRecord::Base
  belongs_to :phone_segment
end

#<===================================================

module DateManager
  class CapturePhoneSegments
    CM = [134, 135, 136, 137, 138, 139, 147, 150,151, 152, 157, 158, 159, 178, 182, 183, 184, 187, 188]
    CU = [130, 131, 132, 145, 155, 156, 176, 185, 186]
    CT = [133, 153, 177, 180, 181, 189]
    URL_PREFIX = "http://www.67cha.com/mobile/"
    URL_SUFFIX = ".html"
    HOME_DIR = "/Users/evanchiu/enterprise/code/capture_phone_location"
    class << self

      def gen_phone_segments phone_prefix
        beginning_num = "#{phone_prefix}0000"
        end_num = "#{phone_prefix}9999"
        puts "Phone Segments Range: [#{beginning_num}-#{end_num}]"
        (beginning_num..end_num)
      end

      def capture_responses_by_curb phone_segments
        responses = {}
        m = Curl::Multi.new
        succ = 0
        failed = 0
        phone_segments.each do |phone_seg|
          url = "#{URL_PREFIX}#{phone_seg}#{URL_SUFFIX}"
          c = Curl::Easy.new(url) do|curl|
            curl.follow_location = true
            curl.on_success {|easy|
              responses[phone_seg] = easy.body_str
              succ += 1
            }
            curl.on_missing{|easy|
              #$bad.info phone_seg
              failed += 1
            }
            curl.on_failure{|easy|
              #$bad.info phone_seg
              failed += 1
            }
          end
          m.add(c)
        end
        m.perform
        puts "Capture Succ: #{succ}, Failed: #{failed}"
        responses
      end

      def capture_responses phone_segments
        puts "Starts to capture the responses..."
        connection = Faraday.new(:url => 'http://www.67cha.com') do |faraday|
          faraday.request  :url_encoded             # form-encode POST params
          # faraday.response :logger                  # log requests to STDOUT
          faraday.adapter  Faraday.default_adapter  # make requests with Net::HTTP
        end
        responses = {}
        succ = 0
        failed = 0
        phone_segments.each do |phone_seg|
          begin
            response = connection.get "/mobile/#{phone_seg}.html"
            if response.success?
              responses[phone_seg] = response.body
              succ += 1
            else
              failed += 1
            end
          rescue Exception => e
            $err.info phone_seg
            $err.info e
            failed += 1
            next
          end
        end
        puts "Capture Succ: #{succ}, Failed: #{failed}"
        responses
      end

      def parse_http_document http_responses
        puts "Start to parse html document and pick out the usefull info..."
        http_doc = ""
        succ = 0
        failed =0
        http_responses.each do |k,v|
          begin
            http_doc = Nokogiri::HTML(v)
            phone_segment_info = http_doc.css('li.value').map(&:content)
            raise "failed" if phone_segment_info.empty? or phone_segment_info.size < 4
            r = PhoneSegment.find_or_initialize_by(phone_seg: phone_segment_info[0])
            location = phone_segment_info[1].split
            unless location.empty?
              r.province = location[0]
              r.city = location.size.eql?(2) ? location[1] : location[0]
            end
            r.operator = phone_segment_info[2]
            r.area_code = phone_segment_info[3]
            succ += 1 if r.save
          rescue Exception => e
            $err.info k
            $err.info e
            failed += 1
            next
          end
        end
        puts "Parsed Total: #{http_responses.size}, Succ: #{succ}, Failed: #{failed}."
      end

      def clear_logs
        puts "Clear all logs."
        `echo '' > #{HOME_DIR}/err.log`
        `echo '' > #{HOME_DIR}/bad.log`
        `echo '' > #{HOME_DIR}/database.log`
      end

      def init_failed_phone_segments
        count = 0
        (CM + CU + CT).each do |phone_prefix|
          phone_segments = gen_phone_segments phone_prefix
          phone_segments.each do |phone_segment|
            FailedPhoneSegment.find_or_create_by(phone_seg: phone_segment)
            count += 1
          end
        end
        puts "Total Count: #{count}"
      end

      def pick_phone_segments num
        records = FailedPhoneSegment.limit(num)
        records.map(&:phone_seg)
      end

      def failed_phone_segments_count
        FailedPhoneSegment.count
      end

      def run
        clear_logs
        init_failed_phone_segments
        while(failed_phone_segments_count > 0)
          phone_segments = pick_phone_segments 100
          http_responses = capture_responses phone_segments
          parse_http_document http_responses
          puts "Left: #{failed_phone_segments_count}"
        end
      end
    end
  end
end

DateManager::CapturePhoneSegments.run
