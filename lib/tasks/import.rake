require 'net/http'
require 'ruby-progressbar'
require 'zip/zip'

namespace :geonames_dump do
  namespace :import do
    CACHE_DIR = "#{Rails.root}/db/geonames_cache"

    GEONAMES_FEATURES_COL_NAME = [
        :geonameid, :name, :asciiname, :alternatenames, :latitude, :longitude, :feature_class,
        :feature, :country, :cc2, :admin1, :admin2, :admin3, :admin4, :population, :elevation,
        :gtopo30, :timezone, :modification
      ]
    GEONAMES_COUNTRIES_COL_NAME = [
        :iso, :iso3, :iso_numeric, :fips, :country, :capital, :area, :population, :continent,
        :tld, :currency_code, :currency_name, :phone, :postal_code_format, :postal_code_regex,
        :languages, :geonameid, :neighbours, :equivalent_fips_code
      ]
    GEONAMES_ADMINS_COL_NAME = [ :code, :name, :asciiname, :geonameid ]

    desc 'Build the geonames download cache directory'
    task :build_cache do
      Dir::mkdir(CACHE_DIR) rescue nil
    end

    desc 'Import all geonames data. Should be performed on a clean install.'
    task :all => [:build_cache, :countries, :cities, :admin1, :admin2]

    desc 'Import all cities, regardless of population. Download requires about 5M.'
    task :cities => [:build_cache, :cities15000, :cities5000, :cities1000]
    
    desc 'Import feature data. Specify Country ISO code for just a single country. NOTE: This task can take a long time!'
    task :features => [:build_cache, :environment] do
      download_file = ENV['COUNTRY'].present? ? ENV['COUNTRY'].upcase : 'allCountries'
      zip_filename = download_file+'.zip'

      txt_file = get_or_download("http://download.geonames.org/export/dump/#{zip_filename}")

      # Import into the database.
      File.open(txt_file) do |f|
        VALID_FEATURES = %w[ADMIN1]
        feature_attrs = VALID_FEATURES & ENV.keys
        # Filter feature rows according to optional command line params.
#        insert_features(f, GeonamesFeature, :title => 'Features') do |feature|
#          feature_attrs.all?{ |attr| feature[attr.downcase.to_sym] == ENV[attr]}
#        end
        # TODO: add feature selection
        insert_data(f, GEONAMES_FEATURES_COL_NAME, GeonamesCity, :title => "Features")
      end
    end

    # geonames:import:citiesNNN where NNN is population size.
    %w[15000 5000 1000].each do |population|
      desc "Import cities with population greater than #{population}"
      task "cities#{population}".to_sym => [:build_cache, :environment] do

        txt_file = get_or_download("http://download.geonames.org/export/dump/cities#{population}.zip")

        # Import into the database.
        File.open(txt_file) do |f|
          insert_data(f, GEONAMES_FEATURES_COL_NAME, GeonamesCity, :title => "cities of #{population}")
        end
      end
    end

    desc 'Import country information'
    task :countries => :environment do
      txt_file = get_or_download('http://download.geonames.org/export/dump/countryInfo.txt')

      # Import into the database.
      File.open(txt_file) do |f|
        insert_data(f, GEONAMES_COUNTRIES_COL_NAME, GeonamesCountry, :title => "Countries")
      end
    end
    
    desc 'Import admin1 codes'
    task :admin1 => [:build_cache, :environment] do
      txt_file = get_or_download('http://download.geonames.org/export/dump/admin1CodesASCII.txt')

      # Import into the database.
      File.open(txt_file) do |f|
        insert_data(f, GEONAMES_ADMINS_COL_NAME, GeonamesAdmin1, :title => "Admin1 subdivisions") do |klass, attributes, col_value, idx|
          col_value.gsub!('(general)', '')
          col_value.strip!
          if idx == 0
            country, admin1 = col_value.split('.')
            attributes[:country] = country.strip
            attributes[:admin1] = admin1.strip rescue nil
          else
            attributes[GEONAMES_ADMINS_COL_NAME[idx]] = col_value
          end
        end
      end
    end

    desc 'Import admin2 codes'
    task :admin2 => [:build_cache, :environment] do
      txt_file = get_or_download('http://download.geonames.org/export/dump/admin2CodesASCII.txt')

      # Import into the database.
      File.open(txt_file) do |f|
        insert_data(f, GEONAMES_ADMINS_COL_NAME, GeonamesAdmin2, :title => "Admin2 subdivisions") do |klass, attributes, col_value, idx|
          col_value.gsub!('(general)', '')
          if idx == 0
            country, admin1, admin2 = col_value.split('.')
            attributes[:country] = country.strip
            attributes[:admin1] = admin1.strip
            attributes[:admin2] = admin2.strip
          else
            attributes[GEONAMES_ADMINS_COL_NAME[idx]] = col_value
          end
        end
      end
    end

    private

    def get_or_download(url, options = {})
      filename = File.basename(url)
      unzip = File.extname(filename) == '.zip'
      txt_filename = unzip ? "#{File.basename(filename, '.zip')}.txt" : filename
      txt_file_in_cache = File.join(CACHE_DIR, options[:txt_file] || txt_filename)
      zip_file_in_cache = File.join(CACHE_DIR, filename)

      unless File::exist?(txt_file_in_cache)
        puts 'file doesn\'t exists'
        if unzip
          download(url, zip_file_in_cache)
          unzip_file(zip_file_in_cache, CACHE_DIR)
        else
          download(url, txt_file_in_cache)
        end
      else
        puts "file already exists : #{txt_file_in_cache}"
      end

      ret = (File::exist?(txt_file_in_cache) ? txt_file_in_cache : nil)
    end

    def unzip_file(file, destination)
      puts "unzipping #{file}"
      Zip::ZipFile.open(file) do |zip_file|
        zip_file.each do |f|
          f_path = File.join(destination, f.name)
          FileUtils.mkdir_p(File.dirname(f_path))
          zip_file.extract(f, f_path) unless File.exist?(f_path)
        end
      end
    end

    def download(url, output)
      File.open(output, "wb") do |file|
        body = fetch(url)
        puts "Writing #{url} to #{output}"
        file.write(body)
      end
    end
    
    def fetch(url)
      puts "Fetching #{url}"
      url = URI.parse(url)
      req = Net::HTTP::Get.new(url.path)
      res = Net::HTTP.start(url.host, url.port) {|http| http.request(req)}
      return res.body
    end
    
    # Insert features from a file. Pass a block that returns true/false to include/exclude the feature.
    def insert_features(file_fd, klass = GeonamesFeature, options = {}, &block)
      # Setup nice progress output.
      file_size = file_fd.stat.size
      title = options[:title] || 'Feature Import'
      progress_bar = ProgressBar.create(:title => title, :total => file_size, :format => '%a |%b>%i| %p%% %t')

      col_names = [
        :geonameid,
        :name,
        :asciiname,
        :alternatenames,
        :latitude,
        :longitude,
        :feature_class,
        :feature,
        :country,
        :cc2,
        :admin1,
        :admin2,
        :admin3,
        :admin4,
        :population,
        :elevation,
        :gtopo30,
        :timezone,
        :modification
      ]
      file_fd.each_line do |line|
        attributes = {}
        line.strip.split("\t").each_with_index do |col_value, i|
          col = col_names[i]
          attributes[col] = col_value
        end
        
        if (attributes[:feature] == "PPL")
          klass = GeonamesCity
        end
        klass.create(attributes) #if filter?(attributes) && (block && block.call(attributes))

        # w00t! Friendly output FTW!
        #progress_bar.set(file_fd.pos)
        progress_bar.progress = file_fd.pos
      end
    end

    def insert_data(file_fd, col_names, main_klass = GeonamesFeature, options = {}, &block)
      # Setup nice progress output.
      file_size = file_fd.stat.size
      title = options[:title] || 'Feature Import'
      progress_bar = ProgressBar.create(:title => title, :total => file_size, :format => '%a |%b>%i| %p%% %t')

      file_fd.each_line do |line|
        # prepare data
        attributes = {}
        klass = main_klass

        # skip comments
        next if line.start_with?('#')

        # read values
        line.strip.split("\t").each_with_index do |col_value, idx|
          col = col_names[idx]

          # skip leading and trailing whitespace
          col_value.strip!

          # block may change the type of object to create
          if block_given?
            yield klass, attributes, col_value, idx
          else
            attributes[col] = col_value
          end
        end

        # create object
        klass.create(attributes) #if filter?(attributes) && (block && block.call(attributes))

        # move progress bar
        progress_bar.progress = file_fd.pos
      end
    end

    # Return true when either:
    #  no filter keys apply.
    #  all applicable filter keys include the filter value.
    def filter?(attributes)
      return attributes.keys.all?{|key| filter_keyvalue?(key, attributes[key])}
    end

    def filter_keyvalue?(col, col_value)
      return true unless ENV[col.to_s]
      return ENV[col.to_s].split('|').include?(col_value.to_s)
    end

  end
end