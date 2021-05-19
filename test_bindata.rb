require 'bindata'
class RpmHeader < BinData::Record
  endian :big
  string :magic, :length => 4, :assert => "\xED\xAB\xEE\xDB".unpack('A4').first
  uint8  :rpm_format_maj, :assert => 3
  uint8  :rpm_format_min                 #
  uint16 :file_type                      # 0 = binary, 1 = source
  uint16 :arch                           # 1 = linux
  string :name, :length => 66            #
  uint16 :os                             #
  uint16 :signature_version              # must accept 5
  string :reserved, :length => 16         # should be all zeros
#  uint16 :index_count                    # number of header index entries
#  uint16 :store_size                     # total size, in bytes, of the data store
  string :header_structure_header, :length => 3, :assert => "\x8E\xAD\xE8".unpack('A3').first
  uint8  :header_structure_version
  string :header_reserved, :length => 4  # should be all zeros
  uint32 :index_count
  uint32 :header_structure_bytes
  string :next__, :length => 16
end
header_data = File.read('.rpm-cache/puppet-agent-6.22.1-1.el7.x86_64.rpm',1024)
rpm_header = RpmHeader.new
rpm_header.read header_data
require 'pry'; binding.pry
