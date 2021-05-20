require 'bindata'
# ref https://refspecs.linuxbase.org/LSB_3.1.1/LSB-Core-generic/LSB-Core-generic/pkgformat.html


class RpmHeader < BinData::Record
  MAGIC_RPM_HEADER = "\xED\xAB\xEE\xDB".unpack('A4').first
  MAGIC_RPM_INDEX  = "\x8E\xAD\xE8".unpack('A3').first

  endian :big
  # struct rpmlead
  string :magic, :length => 4, :assert => MAGIC_RPM_HEADER
  uint8  :rpm_format_maj, :assert => 3
  uint8  :rpm_format_min                 #
  uint16 :file_type                      # 0 = binary, 1 = source
  uint16 :arch                           # 1 = linux
  string :name, :length => 66, :trim_padding => true
  uint16 :os                             #
  uint16 :signature_version              # must accept 5
  skip  :length => 16                    # should be all zeros
  # struct rpmheader
  string :header_structure_header, :length => 3, :assert => MAGIC_RPM_INDEX
  uint8  :header_structure_version
  string :header_reserved, :length => 4  # should be all zeros
  uint32 :index_count                    # number of Index Records
  uint32 :header_structure_bytes         # size in bytes of the storage area
                                         # for the data pointed to by the Index
                                         # Records.
  # struct rpmhdrindex
  array :rpm_tag_index, initial_length: :index_count do
    uint32 :tag
    uint32 :tag_type
    uint32 :tag_offset
    uint32 :element_count
  end

  RPM_INDEX_TYPE_CHOICES = {
    #2 => BinData::Int8,
    #3 => BinData::Int16,
    4 => BinData::Int32le,
    6 => BinData::Stringz,
    7 => BinData::Uint8,
  }

  array :rpm_tag_data, initial_length: :index_count do
    choice(
      selection: lambda { rpm_tag_index[index].tag_type },
      choices: RPM_INDEX_TYPE_CHOICES,
      read_length: lambda { rpm_tag_index[index].element_count }
    )
  end
end
header_data = File.read('.rpm-cache/puppet-agent-6.22.1-1.el7.x86_64.rpm',1024)
rpm_header = RpmHeader.new
rpm_header.read header_data
require 'pry'
puts rpm_header.pretty_inspect
binding.pry
