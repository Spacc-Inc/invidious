# "Invidious" (which is an alternative front-end to YouTube)
# Copyright (C) 2019  Omar Roth
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require "digest/md5"
require "file_utils"
require "kemal"
require "openssl/hmac"
require "option_parser"
require "pg"
require "sqlite3"
require "xml"
require "yaml"
require "compress/zip"
require "protodec/utils"
require "./invidious/helpers/*"
require "./invidious/*"
require "./invidious/channels/*"
require "./invidious/routes/**"
require "./invidious/jobs/**"

CONFIG   = Config.load
HMAC_KEY = CONFIG.hmac_key || Random::Secure.hex(32)

PG_DB           = DB.open CONFIG.database_url
ARCHIVE_URL     = URI.parse("https://archive.org")
LOGIN_URL       = URI.parse("https://accounts.google.com")
PUBSUB_URL      = URI.parse("https://pubsubhubbub.appspot.com")
REDDIT_URL      = URI.parse("https://www.reddit.com")
TEXTCAPTCHA_URL = URI.parse("https://textcaptcha.com")
YT_URL          = URI.parse("https://www.youtube.com")
HOST_URL        = make_host_url(Kemal.config)

CHARS_SAFE         = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
TEST_IDS           = {"AgbeGFYluEA", "BaW_jenozKc", "a9LDPn-MO4I", "ddFvjfvPnqk", "iqKdEhx-dD4"}
MAX_ITEMS_PER_PAGE = 1500

REQUEST_HEADERS_WHITELIST  = {"accept", "accept-encoding", "cache-control", "content-length", "if-none-match", "range"}
RESPONSE_HEADERS_BLACKLIST = {"access-control-allow-origin", "alt-svc", "server"}
HTTP_CHUNK_SIZE            = 10485760 # ~10MB

CURRENT_BRANCH  = {{ "#{`git branch | sed -n '/* /s///p'`.strip}" }}
CURRENT_COMMIT  = {{ "#{`git rev-list HEAD --max-count=1 --abbrev-commit`.strip}" }}
CURRENT_VERSION = {{ "#{`git log -1 --format=%ci | awk '{print $1}' | sed s/-/./g`.strip}" }}

# This is used to determine the `?v=` on the end of file URLs (for cache busting). We
# only need to expire modified assets, so we can use this to find the last commit that changes
# any assets
ASSET_COMMIT = {{ "#{`git rev-list HEAD --max-count=1 --abbrev-commit -- assets`.strip}" }}

SOFTWARE = {
  "name"    => "invidious",
  "version" => "#{CURRENT_VERSION}-#{CURRENT_COMMIT}",
  "branch"  => "#{CURRENT_BRANCH}",
}

YT_POOL = YoutubeConnectionPool.new(YT_URL, capacity: CONFIG.pool_size, timeout: 2.0, use_quic: CONFIG.use_quic)

# CLI
Kemal.config.extra_options do |parser|
  parser.banner = "Usage: invidious [arguments]"
  parser.on("-c THREADS", "--channel-threads=THREADS", "Number of threads for refreshing channels (default: #{CONFIG.channel_threads})") do |number|
    begin
      CONFIG.channel_threads = number.to_i
    rescue ex
      puts "THREADS must be integer"
      exit
    end
  end
  parser.on("-f THREADS", "--feed-threads=THREADS", "Number of threads for refreshing feeds (default: #{CONFIG.feed_threads})") do |number|
    begin
      CONFIG.feed_threads = number.to_i
    rescue ex
      puts "THREADS must be integer"
      exit
    end
  end
  parser.on("-o OUTPUT", "--output=OUTPUT", "Redirect output (default: #{CONFIG.output})") do |output|
    CONFIG.output = output
  end
  parser.on("-l LEVEL", "--log-level=LEVEL", "Log level, one of #{LogLevel.values} (default: #{CONFIG.log_level})") do |log_level|
    CONFIG.log_level = LogLevel.parse(log_level)
  end
  parser.on("-v", "--version", "Print version") do
    puts SOFTWARE.to_pretty_json
    exit
  end
end

Kemal::CLI.new ARGV

if CONFIG.output.upcase != "STDOUT"
  FileUtils.mkdir_p(File.dirname(CONFIG.output))
end
OUTPUT = CONFIG.output.upcase == "STDOUT" ? STDOUT : File.open(CONFIG.output, mode: "a")
LOGGER = Invidious::LogHandler.new(OUTPUT, CONFIG.log_level)

# Check table integrity
if CONFIG.check_tables
  check_enum(PG_DB, "privacy", PlaylistPrivacy)

  check_table(PG_DB, "channels", InvidiousChannel)
  check_table(PG_DB, "channel_videos", ChannelVideo)
  check_table(PG_DB, "playlists", InvidiousPlaylist)
  check_table(PG_DB, "playlist_videos", PlaylistVideo)
  check_table(PG_DB, "nonces", Nonce)
  check_table(PG_DB, "session_ids", SessionId)
  check_table(PG_DB, "users", User)
  check_table(PG_DB, "videos", Video)

  if CONFIG.cache_annotations
    check_table(PG_DB, "annotations", Annotation)
  end
end

# Start jobs

if CONFIG.channel_threads > 0
  Invidious::Jobs.register Invidious::Jobs::RefreshChannelsJob.new(PG_DB)
end

if CONFIG.feed_threads > 0
  Invidious::Jobs.register Invidious::Jobs::RefreshFeedsJob.new(PG_DB)
end

DECRYPT_FUNCTION = DecryptFunction.new(CONFIG.decrypt_polling)
if CONFIG.decrypt_polling
  Invidious::Jobs.register Invidious::Jobs::UpdateDecryptFunctionJob.new
end

if CONFIG.statistics_enabled
  Invidious::Jobs.register Invidious::Jobs::StatisticsRefreshJob.new(PG_DB, SOFTWARE)
end

if (CONFIG.use_pubsub_feeds.is_a?(Bool) && CONFIG.use_pubsub_feeds.as(Bool)) || (CONFIG.use_pubsub_feeds.is_a?(Int32) && CONFIG.use_pubsub_feeds.as(Int32) > 0)
  Invidious::Jobs.register Invidious::Jobs::SubscribeToFeedsJob.new(PG_DB, HMAC_KEY)
end

if CONFIG.popular_enabled
  Invidious::Jobs.register Invidious::Jobs::PullPopularVideosJob.new(PG_DB)
end

if CONFIG.captcha_key
  Invidious::Jobs.register Invidious::Jobs::BypassCaptchaJob.new
end

connection_channel = Channel({Bool, Channel(PQ::Notification)}).new(32)
Invidious::Jobs.register Invidious::Jobs::NotificationJob.new(connection_channel, CONFIG.database_url)

Invidious::Jobs.start_all

def popular_videos
  Invidious::Jobs::PullPopularVideosJob::POPULAR_VIDEOS.get
end

before_all do |env|
  preferences = begin
    Preferences.from_json(URI.decode_www_form(env.request.cookies["PREFS"]?.try &.value || "{}"))
  rescue
    Preferences.from_json("{}")
  end

  env.set "preferences", preferences
  env.response.headers["X-XSS-Protection"] = "1; mode=block"
  env.response.headers["X-Content-Type-Options"] = "nosniff"

  # Allow media resources to be loaded from google servers
  # TODO: check if *.youtube.com can be removed
  if CONFIG.disabled?("local") || !preferences.local
    extra_media_csp = " https://*.googlevideo.com:443 https://*.youtube.com:443"
  else
    extra_media_csp = ""
  end

  # Only allow the pages at /embed/* to be embedded
  if env.request.resource.starts_with?("/embed")
    frame_ancestors = "'self' http: https:"
  else
    frame_ancestors = "'none'"
  end

  # TODO: Remove style-src's 'unsafe-inline', requires to remove all
  # inline styles (<style> [..] </style>, style=" [..] ")
  env.response.headers["Content-Security-Policy"] = {
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data:",
    "font-src 'self' data:",
    "connect-src 'self'",
    "manifest-src 'self'",
    "media-src 'self' blob:" + extra_media_csp,
    "child-src 'self' blob:",
    "frame-src 'self'",
    "frame-ancestors " + frame_ancestors,
  }.join("; ")

  env.response.headers["Referrer-Policy"] = "same-origin"

  # Ask the chrom*-based browsers to disable FLoC
  # See: https://blog.runcloud.io/google-floc/
  env.response.headers["Permissions-Policy"] = "interest-cohort=()"

  if (Kemal.config.ssl || CONFIG.https_only) && CONFIG.hsts
    env.response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains; preload"
  end

  next if {
            "/sb/",
            "/vi/",
            "/s_p/",
            "/yts/",
            "/ggpht/",
            "/api/manifest/",
            "/videoplayback",
            "/latest_version",
          }.any? { |r| env.request.resource.starts_with? r }

  if env.request.cookies.has_key? "SID"
    sid = env.request.cookies["SID"].value

    if sid.starts_with? "v1:"
      raise "Cannot use token as SID"
    end

    # Invidious users only have SID
    if !env.request.cookies.has_key? "SSID"
      if email = PG_DB.query_one?("SELECT email FROM session_ids WHERE id = $1", sid, as: String)
        user = PG_DB.query_one("SELECT * FROM users WHERE email = $1", email, as: User)
        csrf_token = generate_response(sid, {
          ":authorize_token",
          ":playlist_ajax",
          ":signout",
          ":subscription_ajax",
          ":token_ajax",
          ":watch_ajax",
        }, HMAC_KEY, PG_DB, 1.week)

        preferences = user.preferences
        env.set "preferences", preferences

        env.set "sid", sid
        env.set "csrf_token", csrf_token
        env.set "user", user
      end
    else
      headers = HTTP::Headers.new
      headers["Cookie"] = env.request.headers["Cookie"]

      begin
        user, sid = get_user(sid, headers, PG_DB, false)
        csrf_token = generate_response(sid, {
          ":authorize_token",
          ":playlist_ajax",
          ":signout",
          ":subscription_ajax",
          ":token_ajax",
          ":watch_ajax",
        }, HMAC_KEY, PG_DB, 1.week)

        preferences = user.preferences
        env.set "preferences", preferences

        env.set "sid", sid
        env.set "csrf_token", csrf_token
        env.set "user", user
      rescue ex
      end
    end
  end

  dark_mode = convert_theme(env.params.query["dark_mode"]?) || preferences.dark_mode.to_s
  thin_mode = env.params.query["thin_mode"]? || preferences.thin_mode.to_s
  thin_mode = thin_mode == "true"
  locale = env.params.query["hl"]? || preferences.locale

  preferences.dark_mode = dark_mode
  preferences.thin_mode = thin_mode
  preferences.locale = locale
  env.set "preferences", preferences

  current_page = env.request.path
  if env.request.query
    query = HTTP::Params.parse(env.request.query.not_nil!)

    if query["referer"]?
      query["referer"] = get_referer(env, "/")
    end

    current_page += "?#{query}"
  end

  env.set "current_page", URI.encode_www_form(current_page)
end

Invidious::Routing.get "/", Invidious::Routes::Misc, :home
Invidious::Routing.get "/privacy", Invidious::Routes::Misc, :privacy
Invidious::Routing.get "/licenses", Invidious::Routes::Misc, :licenses

Invidious::Routing.get "/channel/:ucid", Invidious::Routes::Channels, :home
Invidious::Routing.get "/channel/:ucid/home", Invidious::Routes::Channels, :home
Invidious::Routing.get "/channel/:ucid/videos", Invidious::Routes::Channels, :videos
Invidious::Routing.get "/channel/:ucid/playlists", Invidious::Routes::Channels, :playlists
Invidious::Routing.get "/channel/:ucid/community", Invidious::Routes::Channels, :community
Invidious::Routing.get "/channel/:ucid/about", Invidious::Routes::Channels, :about

["", "/videos", "/playlists", "/community", "/about"].each do |path|
  # /c/LinusTechTips
  Invidious::Routing.get "/c/:user#{path}", Invidious::Routes::Channels, :brand_redirect
  # /user/linustechtips | Not always the same as /c/
  Invidious::Routing.get "/user/:user#{path}", Invidious::Routes::Channels, :brand_redirect
  # /attribution_link?a=anything&u=/channel/UCZYTClx2T1of7BRZ86-8fow
  Invidious::Routing.get "/attribution_link#{path}", Invidious::Routes::Channels, :brand_redirect
  # /profile?user=linustechtips
  Invidious::Routing.get "/profile/#{path}", Invidious::Routes::Channels, :profile
end

Invidious::Routing.get "/watch", Invidious::Routes::Watch, :handle
Invidious::Routing.get "/watch/:id", Invidious::Routes::Watch, :redirect
Invidious::Routing.get "/shorts/:id", Invidious::Routes::Watch, :redirect
Invidious::Routing.get "/w/:id", Invidious::Routes::Watch, :redirect
Invidious::Routing.get "/v/:id", Invidious::Routes::Watch, :redirect
Invidious::Routing.get "/e/:id", Invidious::Routes::Watch, :redirect
Invidious::Routing.get "/redirect", Invidious::Routes::Misc, :cross_instance_redirect

Invidious::Routing.get "/embed/", Invidious::Routes::Embed, :redirect
Invidious::Routing.get "/embed/:id", Invidious::Routes::Embed, :show

Invidious::Routing.get "/view_all_playlists", Invidious::Routes::Playlists, :index
Invidious::Routing.get "/create_playlist", Invidious::Routes::Playlists, :new
Invidious::Routing.post "/create_playlist", Invidious::Routes::Playlists, :create
Invidious::Routing.get "/subscribe_playlist", Invidious::Routes::Playlists, :subscribe
Invidious::Routing.get "/delete_playlist", Invidious::Routes::Playlists, :delete_page
Invidious::Routing.post "/delete_playlist", Invidious::Routes::Playlists, :delete
Invidious::Routing.get "/edit_playlist", Invidious::Routes::Playlists, :edit
Invidious::Routing.post "/edit_playlist", Invidious::Routes::Playlists, :update
Invidious::Routing.get "/add_playlist_items", Invidious::Routes::Playlists, :add_playlist_items_page
Invidious::Routing.post "/playlist_ajax", Invidious::Routes::Playlists, :playlist_ajax
Invidious::Routing.get "/playlist", Invidious::Routes::Playlists, :show
Invidious::Routing.get "/mix", Invidious::Routes::Playlists, :mix

Invidious::Routing.get "/opensearch.xml", Invidious::Routes::Search, :opensearch
Invidious::Routing.get "/results", Invidious::Routes::Search, :results
Invidious::Routing.get "/search", Invidious::Routes::Search, :search

Invidious::Routing.get "/login", Invidious::Routes::Login, :login_page
Invidious::Routing.post "/login", Invidious::Routes::Login, :login
Invidious::Routing.post "/signout", Invidious::Routes::Login, :signout

Invidious::Routing.get "/preferences", Invidious::Routes::PreferencesRoute, :show
Invidious::Routing.post "/preferences", Invidious::Routes::PreferencesRoute, :update
Invidious::Routing.get "/toggle_theme", Invidious::Routes::PreferencesRoute, :toggle_theme

define_v1_api_routes()
define_api_manifest_routes()
define_video_playback_routes()

# Users

post "/watch_ajax" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env, "/feed/subscriptions")

  redirect = env.params.query["redirect"]?
  redirect ||= "true"
  redirect = redirect == "true"

  if !user
    if redirect
      next env.redirect referer
    else
      next error_json(403, "No such user")
    end
  end

  user = user.as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  id = env.params.query["id"]?
  if !id
    env.response.status_code = 400
    next
  end

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    if redirect
      next error_template(400, ex)
    else
      next error_json(400, ex)
    end
  end

  if env.params.query["action_mark_watched"]?
    action = "action_mark_watched"
  elsif env.params.query["action_mark_unwatched"]?
    action = "action_mark_unwatched"
  else
    next env.redirect referer
  end

  case action
  when "action_mark_watched"
    if !user.watched.includes? id
      PG_DB.exec("UPDATE users SET watched = array_append(watched, $1) WHERE email = $2", id, user.email)
    end
  when "action_mark_unwatched"
    PG_DB.exec("UPDATE users SET watched = array_remove(watched, $1) WHERE email = $2", id, user.email)
  else
    next error_json(400, "Unsupported action #{action}")
  end

  if redirect
    env.redirect referer
  else
    env.response.content_type = "application/json"
    "{}"
  end
end

# /modify_notifications
# will "ding" all subscriptions.
# /modify_notifications?receive_all_updates=false&receive_no_updates=false
# will "unding" all subscriptions.
get "/modify_notifications" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env, "/")

  redirect = env.params.query["redirect"]?
  redirect ||= "false"
  redirect = redirect == "true"

  if !user
    if redirect
      next env.redirect referer
    else
      next error_json(403, "No such user")
    end
  end

  user = user.as(User)

  if !user.password
    channel_req = {} of String => String

    channel_req["receive_all_updates"] = env.params.query["receive_all_updates"]? || "true"
    channel_req["receive_no_updates"] = env.params.query["receive_no_updates"]? || ""
    channel_req["receive_post_updates"] = env.params.query["receive_post_updates"]? || "true"

    channel_req.reject! { |k, v| v != "true" && v != "false" }

    headers = HTTP::Headers.new
    headers["Cookie"] = env.request.headers["Cookie"]

    html = YT_POOL.client &.get("/subscription_manager?disable_polymer=1", headers)

    cookies = HTTP::Cookies.from_client_headers(headers)
    html.cookies.each do |cookie|
      if {"VISITOR_INFO1_LIVE", "YSC", "SIDCC"}.includes? cookie.name
        if cookies[cookie.name]?
          cookies[cookie.name] = cookie
        else
          cookies << cookie
        end
      end
    end
    headers = cookies.add_request_headers(headers)

    if match = html.body.match(/'XSRF_TOKEN': "(?<session_token>[^"]+)"/)
      session_token = match["session_token"]
    else
      next env.redirect referer
    end

    headers["content-type"] = "application/x-www-form-urlencoded"
    channel_req["session_token"] = session_token

    subs = XML.parse_html(html.body)
    subs.xpath_nodes(%q(//a[@class="subscription-title yt-uix-sessionlink"]/@href)).each do |channel|
      channel_id = channel.content.lstrip("/channel/").not_nil!
      channel_req["channel_id"] = channel_id

      YT_POOL.client &.post("/subscription_ajax?action_update_subscription_preferences=1", headers, form: channel_req)
    end
  end

  if redirect
    env.redirect referer
  else
    env.response.content_type = "application/json"
    "{}"
  end
end

post "/subscription_ajax" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env, "/")

  redirect = env.params.query["redirect"]?
  redirect ||= "true"
  redirect = redirect == "true"

  if !user
    if redirect
      next env.redirect referer
    else
      next error_json(403, "No such user")
    end
  end

  user = user.as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    if redirect
      next error_template(400, ex)
    else
      next error_json(400, ex)
    end
  end

  if env.params.query["action_create_subscription_to_channel"]?.try &.to_i?.try &.== 1
    action = "action_create_subscription_to_channel"
  elsif env.params.query["action_remove_subscriptions"]?.try &.to_i?.try &.== 1
    action = "action_remove_subscriptions"
  else
    next env.redirect referer
  end

  channel_id = env.params.query["c"]?
  channel_id ||= ""

  if !user.password
    # Sync subscriptions with YouTube
    subscribe_ajax(channel_id, action, env.request.headers)
  end
  email = user.email

  case action
  when "action_create_subscription_to_channel"
    if !user.subscriptions.includes? channel_id
      get_channel(channel_id, PG_DB, false, false)
      PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = array_append(subscriptions, $1) WHERE email = $2", channel_id, email)
    end
  when "action_remove_subscriptions"
    PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = array_remove(subscriptions, $1) WHERE email = $2", channel_id, email)
  else
    next error_json(400, "Unsupported action #{action}")
  end

  if redirect
    env.redirect referer
  else
    env.response.content_type = "application/json"
    "{}"
  end
end

get "/subscription_manager" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)

  if !user.password
    # Refresh account
    headers = HTTP::Headers.new
    headers["Cookie"] = env.request.headers["Cookie"]

    user, sid = get_user(sid, headers, PG_DB)
  end

  action_takeout = env.params.query["action_takeout"]?.try &.to_i?
  action_takeout ||= 0
  action_takeout = action_takeout == 1

  format = env.params.query["format"]?
  format ||= "rss"

  if user.subscriptions.empty?
    values = "'{}'"
  else
    values = "VALUES #{user.subscriptions.map { |id| %(('#{id}')) }.join(",")}"
  end

  subscriptions = PG_DB.query_all("SELECT * FROM channels WHERE id = ANY(#{values})", as: InvidiousChannel)
  subscriptions.sort_by! { |channel| channel.author.downcase }

  if action_takeout
    if format == "json"
      env.response.content_type = "application/json"
      env.response.headers["content-disposition"] = "attachment"
      playlists = PG_DB.query_all("SELECT * FROM playlists WHERE author = $1 AND id LIKE 'IV%' ORDER BY created", user.email, as: InvidiousPlaylist)

      next JSON.build do |json|
        json.object do
          json.field "subscriptions", user.subscriptions
          json.field "watch_history", user.watched
          json.field "preferences", user.preferences
          json.field "playlists" do
            json.array do
              playlists.each do |playlist|
                json.object do
                  json.field "title", playlist.title
                  json.field "description", html_to_content(playlist.description_html)
                  json.field "privacy", playlist.privacy.to_s
                  json.field "videos" do
                    json.array do
                      PG_DB.query_all("SELECT id FROM playlist_videos WHERE plid = $1 ORDER BY array_position($2, index) LIMIT 500", playlist.id, playlist.index, as: String).each do |video_id|
                        json.string video_id
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    else
      env.response.content_type = "application/xml"
      env.response.headers["content-disposition"] = "attachment"
      export = XML.build do |xml|
        xml.element("opml", version: "1.1") do
          xml.element("body") do
            if format == "newpipe"
              title = "YouTube Subscriptions"
            else
              title = "Invidious Subscriptions"
            end

            xml.element("outline", text: title, title: title) do
              subscriptions.each do |channel|
                if format == "newpipe"
                  xmlUrl = "https://www.youtube.com/feeds/videos.xml?channel_id=#{channel.id}"
                else
                  xmlUrl = "#{HOST_URL}/feed/channel/#{channel.id}"
                end

                xml.element("outline", text: channel.author, title: channel.author,
                  "type": "rss", xmlUrl: xmlUrl)
              end
            end
          end
        end
      end

      next export.gsub(%(<?xml version="1.0"?>\n), "")
    end
  end

  templated "subscription_manager"
end

get "/data_control" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)

  templated "data_control"
end

post "/data_control" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  referer = get_referer(env)

  if user
    user = user.as(User)

    # TODO: Find a way to prevent browser timeout

    HTTP::FormData.parse(env.request) do |part|
      body = part.body.gets_to_end
      next if body.empty?

      # TODO: Unify into single import based on content-type
      case part.name
      when "import_invidious"
        body = JSON.parse(body)

        if body["subscriptions"]?
          user.subscriptions += body["subscriptions"].as_a.map { |a| a.as_s }
          user.subscriptions.uniq!

          user.subscriptions = get_batch_channels(user.subscriptions, PG_DB, false, false)

          PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = $1 WHERE email = $2", user.subscriptions, user.email)
        end

        if body["watch_history"]?
          user.watched += body["watch_history"].as_a.map { |a| a.as_s }
          user.watched.uniq!
          PG_DB.exec("UPDATE users SET watched = $1 WHERE email = $2", user.watched, user.email)
        end

        if body["preferences"]?
          user.preferences = Preferences.from_json(body["preferences"].to_json)
          PG_DB.exec("UPDATE users SET preferences = $1 WHERE email = $2", user.preferences.to_json, user.email)
        end

        if playlists = body["playlists"]?.try &.as_a?
          playlists.each do |item|
            title = item["title"]?.try &.as_s?.try &.delete("<>")
            description = item["description"]?.try &.as_s?.try &.delete("\r")
            privacy = item["privacy"]?.try &.as_s?.try { |privacy| PlaylistPrivacy.parse? privacy }

            next if !title
            next if !description
            next if !privacy

            playlist = create_playlist(PG_DB, title, privacy, user)
            PG_DB.exec("UPDATE playlists SET description = $1 WHERE id = $2", description, playlist.id)

            videos = item["videos"]?.try &.as_a?.try &.each_with_index do |video_id, idx|
              raise InfoException.new("Playlist cannot have more than 500 videos") if idx > 500

              video_id = video_id.try &.as_s?
              next if !video_id

              begin
                video = get_video(video_id, PG_DB)
              rescue ex
                next
              end

              playlist_video = PlaylistVideo.new({
                title:          video.title,
                id:             video.id,
                author:         video.author,
                ucid:           video.ucid,
                length_seconds: video.length_seconds,
                published:      video.published,
                plid:           playlist.id,
                live_now:       video.live_now,
                index:          Random::Secure.rand(0_i64..Int64::MAX),
              })

              video_array = playlist_video.to_a
              args = arg_array(video_array)

              PG_DB.exec("INSERT INTO playlist_videos VALUES (#{args})", args: video_array)
              PG_DB.exec("UPDATE playlists SET index = array_append(index, $1), video_count = cardinality(index) + 1, updated = $2 WHERE id = $3", playlist_video.index, Time.utc, playlist.id)
            end
          end
        end
      when "import_youtube"
        if body[0..4] == "<opml"
          subscriptions = XML.parse(body)
          user.subscriptions += subscriptions.xpath_nodes(%q(//outline[@type="rss"])).map do |channel|
            channel["xmlUrl"].match(/UC[a-zA-Z0-9_-]{22}/).not_nil![0]
          end
        else
          subscriptions = JSON.parse(body)
          user.subscriptions += subscriptions.as_a.compact_map do |entry|
            entry["snippet"]["resourceId"]["channelId"].as_s
          end
        end
        user.subscriptions.uniq!

        user.subscriptions = get_batch_channels(user.subscriptions, PG_DB, false, false)

        PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = $1 WHERE email = $2", user.subscriptions, user.email)
      when "import_freetube"
        user.subscriptions += body.scan(/"channelId":"(?<channel_id>[a-zA-Z0-9_-]{24})"/).map do |md|
          md["channel_id"]
        end
        user.subscriptions.uniq!

        user.subscriptions = get_batch_channels(user.subscriptions, PG_DB, false, false)

        PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = $1 WHERE email = $2", user.subscriptions, user.email)
      when "import_newpipe_subscriptions"
        body = JSON.parse(body)
        user.subscriptions += body["subscriptions"].as_a.compact_map do |channel|
          if match = channel["url"].as_s.match(/\/channel\/(?<channel>UC[a-zA-Z0-9_-]{22})/)
            next match["channel"]
          elsif match = channel["url"].as_s.match(/\/user\/(?<user>.+)/)
            response = YT_POOL.client &.get("/user/#{match["user"]}?disable_polymer=1&hl=en&gl=US")
            html = XML.parse_html(response.body)
            ucid = html.xpath_node(%q(//link[@rel="canonical"])).try &.["href"].split("/")[-1]
            next ucid if ucid
          end

          nil
        end
        user.subscriptions.uniq!

        user.subscriptions = get_batch_channels(user.subscriptions, PG_DB, false, false)

        PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = $1 WHERE email = $2", user.subscriptions, user.email)
      when "import_newpipe"
        Compress::Zip::Reader.open(IO::Memory.new(body)) do |file|
          file.each_entry do |entry|
            if entry.filename == "newpipe.db"
              tempfile = File.tempfile(".db")
              File.write(tempfile.path, entry.io.gets_to_end)
              db = DB.open("sqlite3://" + tempfile.path)

              user.watched += db.query_all("SELECT url FROM streams", as: String).map { |url| url.lchop("https://www.youtube.com/watch?v=") }
              user.watched.uniq!

              PG_DB.exec("UPDATE users SET watched = $1 WHERE email = $2", user.watched, user.email)

              user.subscriptions += db.query_all("SELECT url FROM subscriptions", as: String).map { |url| url.lchop("https://www.youtube.com/channel/") }
              user.subscriptions.uniq!

              user.subscriptions = get_batch_channels(user.subscriptions, PG_DB, false, false)

              PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = $1 WHERE email = $2", user.subscriptions, user.email)

              db.close
              tempfile.delete
            end
          end
        end
      else nil # Ignore
      end
    end
  end

  env.redirect referer
end

get "/change_password" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  csrf_token = generate_response(sid, {":change_password"}, HMAC_KEY, PG_DB)

  templated "change_password"
end

post "/change_password" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  # We don't store passwords for Google accounts
  if !user.password
    next error_template(400, "Cannot change password for Google accounts")
  end

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    next error_template(400, ex)
  end

  password = env.params.body["password"]?
  if !password
    next error_template(401, "Password is a required field")
  end

  new_passwords = env.params.body.select { |k, v| k.match(/^new_password\[\d+\]$/) }.map { |k, v| v }

  if new_passwords.size <= 1 || new_passwords.uniq.size != 1
    next error_template(400, "New passwords must match")
  end

  new_password = new_passwords.uniq[0]
  if new_password.empty?
    next error_template(401, "Password cannot be empty")
  end

  if new_password.bytesize > 55
    next error_template(400, "Password cannot be longer than 55 characters")
  end

  if !Crypto::Bcrypt::Password.new(user.password.not_nil!).verify(password.byte_slice(0, 55))
    next error_template(401, "Incorrect password")
  end

  new_password = Crypto::Bcrypt::Password.create(new_password, cost: 10)
  PG_DB.exec("UPDATE users SET password = $1 WHERE email = $2", new_password.to_s, user.email)

  env.redirect referer
end

get "/delete_account" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  csrf_token = generate_response(sid, {":delete_account"}, HMAC_KEY, PG_DB)

  templated "delete_account"
end

post "/delete_account" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    next error_template(400, ex)
  end

  view_name = "subscriptions_#{sha256(user.email)}"
  PG_DB.exec("DELETE FROM users * WHERE email = $1", user.email)
  PG_DB.exec("DELETE FROM session_ids * WHERE email = $1", user.email)
  PG_DB.exec("DROP MATERIALIZED VIEW #{view_name}")

  env.request.cookies.each do |cookie|
    cookie.expires = Time.utc(1990, 1, 1)
    env.response.cookies << cookie
  end

  env.redirect referer
end

get "/clear_watch_history" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  csrf_token = generate_response(sid, {":clear_watch_history"}, HMAC_KEY, PG_DB)

  templated "clear_watch_history"
end

post "/clear_watch_history" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    next error_template(400, ex)
  end

  PG_DB.exec("UPDATE users SET watched = '{}' WHERE email = $1", user.email)
  env.redirect referer
end

get "/authorize_token" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  csrf_token = generate_response(sid, {":authorize_token"}, HMAC_KEY, PG_DB)

  scopes = env.params.query["scopes"]?.try &.split(",")
  scopes ||= [] of String

  callback_url = env.params.query["callback_url"]?
  if callback_url
    callback_url = URI.parse(callback_url)
  end

  expire = env.params.query["expire"]?.try &.to_i?

  templated "authorize_token"
end

post "/authorize_token" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = env.get("user").as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    next error_template(400, ex)
  end

  scopes = env.params.body.select { |k, v| k.match(/^scopes\[\d+\]$/) }.map { |k, v| v }
  callback_url = env.params.body["callbackUrl"]?
  expire = env.params.body["expire"]?.try &.to_i?

  access_token = generate_token(user.email, scopes, expire, HMAC_KEY, PG_DB)

  if callback_url
    access_token = URI.encode_www_form(access_token)
    url = URI.parse(callback_url)

    if url.query
      query = HTTP::Params.parse(url.query.not_nil!)
    else
      query = HTTP::Params.new
    end

    query["token"] = access_token
    url.query = query.to_s

    env.redirect url.to_s
  else
    csrf_token = ""
    env.set "access_token", access_token
    templated "authorize_token"
  end
end

get "/token_manager" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env, "/subscription_manager")

  if !user
    next env.redirect referer
  end

  user = user.as(User)

  tokens = PG_DB.query_all("SELECT id, issued FROM session_ids WHERE email = $1 ORDER BY issued DESC", user.email, as: {session: String, issued: Time})

  templated "token_manager"
end

post "/token_ajax" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  redirect = env.params.query["redirect"]?
  redirect ||= "true"
  redirect = redirect == "true"

  if !user
    if redirect
      next env.redirect referer
    else
      next error_json(403, "No such user")
    end
  end

  user = user.as(User)
  sid = sid.as(String)
  token = env.params.body["csrf_token"]?

  begin
    validate_request(token, sid, env.request, HMAC_KEY, PG_DB, locale)
  rescue ex
    if redirect
      next error_template(400, ex)
    else
      next error_json(400, ex)
    end
  end

  if env.params.query["action_revoke_token"]?
    action = "action_revoke_token"
  else
    next env.redirect referer
  end

  session = env.params.query["session"]?
  session ||= ""

  case action
  when .starts_with? "action_revoke_token"
    PG_DB.exec("DELETE FROM session_ids * WHERE id = $1 AND email = $2", session, user.email)
  else
    next error_json(400, "Unsupported action #{action}")
  end

  if redirect
    env.redirect referer
  else
    env.response.content_type = "application/json"
    "{}"
  end
end

# Feeds

get "/feed/playlists" do |env|
  env.redirect "/view_all_playlists"
end

get "/feed/top" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  message = translate(locale, "The Top feed has been removed from Invidious.")
  templated "message"
end

get "/feed/popular" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  if CONFIG.popular_enabled
    templated "popular"
  else
    message = translate(locale, "The Popular feed has been disabled by the administrator.")
    templated "message"
  end
end

get "/feed/trending" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  trending_type = env.params.query["type"]?
  trending_type ||= "Default"

  region = env.params.query["region"]?
  region ||= "US"

  begin
    trending, plid = fetch_trending(trending_type, region, locale)
  rescue ex
    next error_template(500, ex)
  end

  templated "trending"
end

get "/feed/subscriptions" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  sid = env.get? "sid"
  referer = get_referer(env)

  if !user
    next env.redirect referer
  end

  user = user.as(User)
  sid = sid.as(String)
  token = user.token

  if user.preferences.unseen_only
    env.set "show_watched", true
  end

  # Refresh account
  headers = HTTP::Headers.new
  headers["Cookie"] = env.request.headers["Cookie"]

  if !user.password
    user, sid = get_user(sid, headers, PG_DB)
  end

  max_results = env.params.query["max_results"]?.try &.to_i?.try &.clamp(0, MAX_ITEMS_PER_PAGE)
  max_results ||= user.preferences.max_results
  max_results ||= CONFIG.default_user_preferences.max_results

  page = env.params.query["page"]?.try &.to_i?
  page ||= 1

  videos, notifications = get_subscription_feed(PG_DB, user, max_results, page)

  # "updated" here is used for delivering new notifications, so if
  # we know a user has looked at their feed e.g. in the past 10 minutes,
  # they've already seen a video posted 20 minutes ago, and don't need
  # to be notified.
  PG_DB.exec("UPDATE users SET notifications = $1, updated = $2 WHERE email = $3", [] of String, Time.utc,
    user.email)
  user.notifications = [] of String
  env.set "user", user

  templated "subscriptions"
end

get "/feed/history" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  user = env.get? "user"
  referer = get_referer(env)

  page = env.params.query["page"]?.try &.to_i?
  page ||= 1

  if !user
    next env.redirect referer
  end

  user = user.as(User)

  max_results = env.params.query["max_results"]?.try &.to_i?.try &.clamp(0, MAX_ITEMS_PER_PAGE)
  max_results ||= user.preferences.max_results
  max_results ||= CONFIG.default_user_preferences.max_results

  if user.watched[(page - 1) * max_results]?
    watched = user.watched.reverse[(page - 1) * max_results, max_results]
  end
  watched ||= [] of String

  templated "history"
end

get "/feed/channel/:ucid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/atom+xml"

  ucid = env.params.url["ucid"]

  params = HTTP::Params.parse(env.params.query["params"]? || "")

  begin
    channel = get_about_info(ucid, locale)
  rescue ex : ChannelRedirect
    next env.redirect env.request.resource.gsub(ucid, ex.channel_id)
  rescue ex
    next error_atom(500, ex)
  end

  response = YT_POOL.client &.get("/feeds/videos.xml?channel_id=#{channel.ucid}")
  rss = XML.parse_html(response.body)

  videos = rss.xpath_nodes("//feed/entry").map do |entry|
    video_id = entry.xpath_node("videoid").not_nil!.content
    title = entry.xpath_node("title").not_nil!.content

    published = Time.parse_rfc3339(entry.xpath_node("published").not_nil!.content)
    updated = Time.parse_rfc3339(entry.xpath_node("updated").not_nil!.content)

    author = entry.xpath_node("author/name").not_nil!.content
    ucid = entry.xpath_node("channelid").not_nil!.content
    description_html = entry.xpath_node("group/description").not_nil!.to_s
    views = entry.xpath_node("group/community/statistics").not_nil!.["views"].to_i64

    SearchVideo.new({
      title:              title,
      id:                 video_id,
      author:             author,
      ucid:               ucid,
      published:          published,
      views:              views,
      description_html:   description_html,
      length_seconds:     0,
      live_now:           false,
      premium:            false,
      premiere_timestamp: nil,
    })
  end

  XML.build(indent: "  ", encoding: "UTF-8") do |xml|
    xml.element("feed", "xmlns:yt": "http://www.youtube.com/xml/schemas/2015",
      "xmlns:media": "http://search.yahoo.com/mrss/", xmlns: "http://www.w3.org/2005/Atom",
      "xml:lang": "en-US") do
      xml.element("link", rel: "self", href: "#{HOST_URL}#{env.request.resource}")
      xml.element("id") { xml.text "yt:channel:#{channel.ucid}" }
      xml.element("yt:channelId") { xml.text channel.ucid }
      xml.element("icon") { xml.text channel.author_thumbnail }
      xml.element("title") { xml.text channel.author }
      xml.element("link", rel: "alternate", href: "#{HOST_URL}/channel/#{channel.ucid}")

      xml.element("author") do
        xml.element("name") { xml.text channel.author }
        xml.element("uri") { xml.text "#{HOST_URL}/channel/#{channel.ucid}" }
      end

      videos.each do |video|
        video.to_xml(channel.auto_generated, params, xml)
      end
    end
  end
end

get "/feed/private" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/atom+xml"

  token = env.params.query["token"]?

  if !token
    env.response.status_code = 403
    next
  end

  user = PG_DB.query_one?("SELECT * FROM users WHERE token = $1", token.strip, as: User)
  if !user
    env.response.status_code = 403
    next
  end

  max_results = env.params.query["max_results"]?.try &.to_i?.try &.clamp(0, MAX_ITEMS_PER_PAGE)
  max_results ||= user.preferences.max_results
  max_results ||= CONFIG.default_user_preferences.max_results

  page = env.params.query["page"]?.try &.to_i?
  page ||= 1

  params = HTTP::Params.parse(env.params.query["params"]? || "")

  videos, notifications = get_subscription_feed(PG_DB, user, max_results, page)

  XML.build(indent: "  ", encoding: "UTF-8") do |xml|
    xml.element("feed", "xmlns:yt": "http://www.youtube.com/xml/schemas/2015",
      "xmlns:media": "http://search.yahoo.com/mrss/", xmlns: "http://www.w3.org/2005/Atom",
      "xml:lang": "en-US") do
      xml.element("link", "type": "text/html", rel: "alternate", href: "#{HOST_URL}/feed/subscriptions")
      xml.element("link", "type": "application/atom+xml", rel: "self",
        href: "#{HOST_URL}#{env.request.resource}")
      xml.element("title") { xml.text translate(locale, "Invidious Private Feed for `x`", user.email) }

      (notifications + videos).each do |video|
        video.to_xml(locale, params, xml)
      end
    end
  end
end

get "/feed/playlist/:plid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/atom+xml"

  plid = env.params.url["plid"]

  params = HTTP::Params.parse(env.params.query["params"]? || "")
  path = env.request.path

  if plid.starts_with? "IV"
    if playlist = PG_DB.query_one?("SELECT * FROM playlists WHERE id = $1", plid, as: InvidiousPlaylist)
      videos = get_playlist_videos(PG_DB, playlist, offset: 0, locale: locale)

      next XML.build(indent: "  ", encoding: "UTF-8") do |xml|
        xml.element("feed", "xmlns:yt": "http://www.youtube.com/xml/schemas/2015",
          "xmlns:media": "http://search.yahoo.com/mrss/", xmlns: "http://www.w3.org/2005/Atom",
          "xml:lang": "en-US") do
          xml.element("link", rel: "self", href: "#{HOST_URL}#{env.request.resource}")
          xml.element("id") { xml.text "iv:playlist:#{plid}" }
          xml.element("iv:playlistId") { xml.text plid }
          xml.element("title") { xml.text playlist.title }
          xml.element("link", rel: "alternate", href: "#{HOST_URL}/playlist?list=#{plid}")

          xml.element("author") do
            xml.element("name") { xml.text playlist.author }
          end

          videos.each do |video|
            video.to_xml(false, xml)
          end
        end
      end
    else
      env.response.status_code = 404
      next
    end
  end

  response = YT_POOL.client &.get("/feeds/videos.xml?playlist_id=#{plid}")
  document = XML.parse(response.body)

  document.xpath_nodes(%q(//*[@href]|//*[@url])).each do |node|
    node.attributes.each do |attribute|
      case attribute.name
      when "url", "href"
        request_target = URI.parse(node[attribute.name]).request_target
        query_string_opt = request_target.starts_with?("/watch?v=") ? "&#{params}" : ""
        node[attribute.name] = "#{HOST_URL}#{request_target}#{query_string_opt}"
      else nil # Skip
      end
    end
  end

  document = document.to_xml(options: XML::SaveOptions::NO_DECL)

  document.scan(/<uri>(?<url>[^<]+)<\/uri>/).each do |match|
    content = "#{HOST_URL}#{URI.parse(match["url"]).request_target}"
    document = document.gsub(match[0], "<uri>#{content}</uri>")
  end

  document
end

get "/feeds/videos.xml" do |env|
  if ucid = env.params.query["channel_id"]?
    env.redirect "/feed/channel/#{ucid}"
  elsif user = env.params.query["user"]?
    env.redirect "/feed/channel/#{user}"
  elsif plid = env.params.query["playlist_id"]?
    env.redirect "/feed/playlist/#{plid}"
  end
end

# Support push notifications via PubSubHubbub

get "/feed/webhook/:token" do |env|
  verify_token = env.params.url["token"]

  mode = env.params.query["hub.mode"]?
  topic = env.params.query["hub.topic"]?
  challenge = env.params.query["hub.challenge"]?

  if !mode || !topic || !challenge
    env.response.status_code = 400
    next
  else
    mode = mode.not_nil!
    topic = topic.not_nil!
    challenge = challenge.not_nil!
  end

  case verify_token
  when .starts_with? "v1"
    _, time, nonce, signature = verify_token.split(":")
    data = "#{time}:#{nonce}"
  when .starts_with? "v2"
    time, signature = verify_token.split(":")
    data = "#{time}"
  else
    env.response.status_code = 400
    next
  end

  # The hub will sometimes check if we're still subscribed after delivery errors,
  # so we reply with a 200 as long as the request hasn't expired
  if Time.utc.to_unix - time.to_i > 432000
    env.response.status_code = 400
    next
  end

  if OpenSSL::HMAC.hexdigest(:sha1, HMAC_KEY, data) != signature
    env.response.status_code = 400
    next
  end

  if ucid = HTTP::Params.parse(URI.parse(topic).query.not_nil!)["channel_id"]?
    PG_DB.exec("UPDATE channels SET subscribed = $1 WHERE id = $2", Time.utc, ucid)
  elsif plid = HTTP::Params.parse(URI.parse(topic).query.not_nil!)["playlist_id"]?
    PG_DB.exec("UPDATE playlists SET subscribed = $1 WHERE id = $2", Time.utc, ucid)
  else
    env.response.status_code = 400
    next
  end

  env.response.status_code = 200
  challenge
end

post "/feed/webhook/:token" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  token = env.params.url["token"]
  body = env.request.body.not_nil!.gets_to_end
  signature = env.request.headers["X-Hub-Signature"].lchop("sha1=")

  if signature != OpenSSL::HMAC.hexdigest(:sha1, HMAC_KEY, body)
    LOGGER.error("/feed/webhook/#{token} : Invalid signature")
    env.response.status_code = 200
    next
  end

  spawn do
    rss = XML.parse_html(body)
    rss.xpath_nodes("//feed/entry").each do |entry|
      id = entry.xpath_node("videoid").not_nil!.content
      author = entry.xpath_node("author/name").not_nil!.content
      published = Time.parse_rfc3339(entry.xpath_node("published").not_nil!.content)
      updated = Time.parse_rfc3339(entry.xpath_node("updated").not_nil!.content)

      video = get_video(id, PG_DB, force_refresh: true)

      # Deliver notifications to `/api/v1/auth/notifications`
      payload = {
        "topic"     => video.ucid,
        "videoId"   => video.id,
        "published" => published.to_unix,
      }.to_json
      PG_DB.exec("NOTIFY notifications, E'#{payload}'")

      video = ChannelVideo.new({
        id:                 id,
        title:              video.title,
        published:          published,
        updated:            updated,
        ucid:               video.ucid,
        author:             author,
        length_seconds:     video.length_seconds,
        live_now:           video.live_now,
        premiere_timestamp: video.premiere_timestamp,
        views:              video.views,
      })

      was_insert = PG_DB.query_one("INSERT INTO channel_videos VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ON CONFLICT (id) DO UPDATE SET title = $2, published = $3,
        updated = $4, ucid = $5, author = $6, length_seconds = $7,
        live_now = $8, premiere_timestamp = $9, views = $10 returning (xmax=0) as was_insert", *video.to_tuple, as: Bool)

      PG_DB.exec("UPDATE users SET notifications = array_append(notifications, $1),
        feed_needs_update = true WHERE $2 = ANY(subscriptions)", video.id, video.ucid) if was_insert
    end
  end

  env.response.status_code = 200
  next
end

# Channels

{"/channel/:ucid/live", "/user/:user/live", "/c/:user/live"}.each do |route|
  get route do |env|
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    # Appears to be a bug in routing, having several routes configured
    # as `/a/:a`, `/b/:a`, `/c/:a` results in 404
    value = env.request.resource.split("/")[2]
    body = ""
    {"channel", "user", "c"}.each do |type|
      response = YT_POOL.client &.get("/#{type}/#{value}/live?disable_polymer=1")
      if response.status_code == 200
        body = response.body
      end
    end

    video_id = body.match(/'VIDEO_ID': "(?<id>[a-zA-Z0-9_-]{11})"/).try &.["id"]?
    if video_id
      params = [] of String
      env.params.query.each do |k, v|
        params << "#{k}=#{v}"
      end
      params = params.join("&")

      url = "/watch?v=#{video_id}"
      if !params.empty?
        url += "&#{params}"
      end

      env.redirect url
    else
      env.redirect "/channel/#{value}"
    end
  end
end

# API Endpoints

{"/api/v1/playlists/:plid", "/api/v1/auth/playlists/:plid"}.each do |route|
  get route do |env|
    locale = LOCALES[env.get("preferences").as(Preferences).locale]?

    env.response.content_type = "application/json"
    plid = env.params.url["plid"]

    offset = env.params.query["index"]?.try &.to_i?
    offset ||= env.params.query["page"]?.try &.to_i?.try { |page| (page - 1) * 100 }
    offset ||= 0

    continuation = env.params.query["continuation"]?

    format = env.params.query["format"]?
    format ||= "json"

    if plid.starts_with? "RD"
      next env.redirect "/api/v1/mixes/#{plid}"
    end

    begin
      playlist = get_playlist(PG_DB, plid, locale)
    rescue ex : InfoException
      next error_json(404, ex)
    rescue ex
      next error_json(404, "Playlist does not exist.")
    end

    user = env.get?("user").try &.as(User)
    if !playlist || playlist.privacy.private? && playlist.author != user.try &.email
      next error_json(404, "Playlist does not exist.")
    end

    response = playlist.to_json(offset, locale, continuation: continuation)

    if format == "html"
      response = JSON.parse(response)
      playlist_html = template_playlist(response)
      index, next_video = response["videos"].as_a.skip(1).select { |video| !video["author"].as_s.empty? }[0]?.try { |v| {v["index"], v["videoId"]} } || {nil, nil}

      response = {
        "playlistHtml" => playlist_html,
        "index"        => index,
        "nextVideo"    => next_video,
      }.to_json
    end

    response
  end
end

get "/api/v1/mixes/:rdid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"

  rdid = env.params.url["rdid"]

  continuation = env.params.query["continuation"]?
  continuation ||= rdid.lchop("RD")[0, 11]

  format = env.params.query["format"]?
  format ||= "json"

  begin
    mix = fetch_mix(rdid, continuation, locale: locale)

    if !rdid.ends_with? continuation
      mix = fetch_mix(rdid, mix.videos[1].id)
      index = mix.videos.index(mix.videos.select { |video| video.id == continuation }[0]?)
    end

    mix.videos = mix.videos[index..-1]
  rescue ex
    next error_json(500, ex)
  end

  response = JSON.build do |json|
    json.object do
      json.field "title", mix.title
      json.field "mixId", mix.id

      json.field "videos" do
        json.array do
          mix.videos.each do |video|
            json.object do
              json.field "title", video.title
              json.field "videoId", video.id
              json.field "author", video.author

              json.field "authorId", video.ucid
              json.field "authorUrl", "/channel/#{video.ucid}"

              json.field "videoThumbnails" do
                json.array do
                  generate_thumbnails(json, video.id)
                end
              end

              json.field "index", video.index
              json.field "lengthSeconds", video.length_seconds
            end
          end
        end
      end
    end
  end

  if format == "html"
    response = JSON.parse(response)
    playlist_html = template_mix(response)
    next_video = response["videos"].as_a.select { |video| !video["author"].as_s.empty? }[0]?.try &.["videoId"]

    response = {
      "playlistHtml" => playlist_html,
      "nextVideo"    => next_video,
    }.to_json
  end

  response
end

# Authenticated endpoints

get "/api/v1/auth/notifications" do |env|
  env.response.content_type = "text/event-stream"

  topics = env.params.query["topics"]?.try &.split(",").uniq.first(1000)
  topics ||= [] of String

  create_notification_stream(env, topics, connection_channel)
end

post "/api/v1/auth/notifications" do |env|
  env.response.content_type = "text/event-stream"

  topics = env.params.body["topics"]?.try &.split(",").uniq.first(1000)
  topics ||= [] of String

  create_notification_stream(env, topics, connection_channel)
end

get "/api/v1/auth/preferences" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)
  user.preferences.to_json
end

post "/api/v1/auth/preferences" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  begin
    preferences = Preferences.from_json(env.request.body || "{}")
  rescue
    preferences = user.preferences
  end

  PG_DB.exec("UPDATE users SET preferences = $1 WHERE email = $2", preferences.to_json, user.email)

  env.response.status_code = 204
end

get "/api/v1/auth/feed" do |env|
  env.response.content_type = "application/json"

  user = env.get("user").as(User)
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  max_results = env.params.query["max_results"]?.try &.to_i?
  max_results ||= user.preferences.max_results
  max_results ||= CONFIG.default_user_preferences.max_results

  page = env.params.query["page"]?.try &.to_i?
  page ||= 1

  videos, notifications = get_subscription_feed(PG_DB, user, max_results, page)

  JSON.build do |json|
    json.object do
      json.field "notifications" do
        json.array do
          notifications.each do |video|
            video.to_json(locale, json)
          end
        end
      end

      json.field "videos" do
        json.array do
          videos.each do |video|
            video.to_json(locale, json)
          end
        end
      end
    end
  end
end

get "/api/v1/auth/subscriptions" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  if user.subscriptions.empty?
    values = "'{}'"
  else
    values = "VALUES #{user.subscriptions.map { |id| %(('#{id}')) }.join(",")}"
  end

  subscriptions = PG_DB.query_all("SELECT * FROM channels WHERE id = ANY(#{values})", as: InvidiousChannel)

  JSON.build do |json|
    json.array do
      subscriptions.each do |subscription|
        json.object do
          json.field "author", subscription.author
          json.field "authorId", subscription.id
        end
      end
    end
  end
end

post "/api/v1/auth/subscriptions/:ucid" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  ucid = env.params.url["ucid"]

  if !user.subscriptions.includes? ucid
    get_channel(ucid, PG_DB, false, false)
    PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = array_append(subscriptions,$1) WHERE email = $2", ucid, user.email)
  end

  # For Google accounts, access tokens don't have enough information to
  # make a request on the user's behalf, which is why we don't sync with
  # YouTube.

  env.response.status_code = 204
end

delete "/api/v1/auth/subscriptions/:ucid" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  ucid = env.params.url["ucid"]

  PG_DB.exec("UPDATE users SET feed_needs_update = true, subscriptions = array_remove(subscriptions, $1) WHERE email = $2", ucid, user.email)

  env.response.status_code = 204
end

get "/api/v1/auth/playlists" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  playlists = PG_DB.query_all("SELECT * FROM playlists WHERE author = $1", user.email, as: InvidiousPlaylist)

  JSON.build do |json|
    json.array do
      playlists.each do |playlist|
        playlist.to_json(0, locale, json)
      end
    end
  end
end

post "/api/v1/auth/playlists" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  title = env.params.json["title"]?.try &.as(String).delete("<>").byte_slice(0, 150)
  if !title
    next error_json(400, "Invalid title.")
  end

  privacy = env.params.json["privacy"]?.try { |privacy| PlaylistPrivacy.parse(privacy.as(String).downcase) }
  if !privacy
    next error_json(400, "Invalid privacy setting.")
  end

  if PG_DB.query_one("SELECT count(*) FROM playlists WHERE author = $1", user.email, as: Int64) >= 100
    next error_json(400, "User cannot have more than 100 playlists.")
  end

  playlist = create_playlist(PG_DB, title, privacy, user)
  env.response.headers["Location"] = "#{HOST_URL}/api/v1/auth/playlists/#{playlist.id}"
  env.response.status_code = 201
  {
    "title"      => title,
    "playlistId" => playlist.id,
  }.to_json
end

patch "/api/v1/auth/playlists/:plid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  plid = env.params.url["plid"]

  playlist = PG_DB.query_one?("SELECT * FROM playlists WHERE id = $1", plid, as: InvidiousPlaylist)
  if !playlist || playlist.author != user.email && playlist.privacy.private?
    next error_json(404, "Playlist does not exist.")
  end

  if playlist.author != user.email
    next error_json(403, "Invalid user")
  end

  title = env.params.json["title"].try &.as(String).delete("<>").byte_slice(0, 150) || playlist.title
  privacy = env.params.json["privacy"]?.try { |privacy| PlaylistPrivacy.parse(privacy.as(String).downcase) } || playlist.privacy
  description = env.params.json["description"]?.try &.as(String).delete("\r") || playlist.description

  if title != playlist.title ||
     privacy != playlist.privacy ||
     description != playlist.description
    updated = Time.utc
  else
    updated = playlist.updated
  end

  PG_DB.exec("UPDATE playlists SET title = $1, privacy = $2, description = $3, updated = $4 WHERE id = $5", title, privacy, description, updated, plid)
  env.response.status_code = 204
end

delete "/api/v1/auth/playlists/:plid" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  plid = env.params.url["plid"]

  playlist = PG_DB.query_one?("SELECT * FROM playlists WHERE id = $1", plid, as: InvidiousPlaylist)
  if !playlist || playlist.author != user.email && playlist.privacy.private?
    next error_json(404, "Playlist does not exist.")
  end

  if playlist.author != user.email
    next error_json(403, "Invalid user")
  end

  PG_DB.exec("DELETE FROM playlist_videos * WHERE plid = $1", plid)
  PG_DB.exec("DELETE FROM playlists * WHERE id = $1", plid)

  env.response.status_code = 204
end

post "/api/v1/auth/playlists/:plid/videos" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  plid = env.params.url["plid"]

  playlist = PG_DB.query_one?("SELECT * FROM playlists WHERE id = $1", plid, as: InvidiousPlaylist)
  if !playlist || playlist.author != user.email && playlist.privacy.private?
    next error_json(404, "Playlist does not exist.")
  end

  if playlist.author != user.email
    next error_json(403, "Invalid user")
  end

  if playlist.index.size >= 500
    next error_json(400, "Playlist cannot have more than 500 videos")
  end

  video_id = env.params.json["videoId"].try &.as(String)
  if !video_id
    next error_json(403, "Invalid videoId")
  end

  begin
    video = get_video(video_id, PG_DB)
  rescue ex
    next error_json(500, ex)
  end

  playlist_video = PlaylistVideo.new({
    title:          video.title,
    id:             video.id,
    author:         video.author,
    ucid:           video.ucid,
    length_seconds: video.length_seconds,
    published:      video.published,
    plid:           plid,
    live_now:       video.live_now,
    index:          Random::Secure.rand(0_i64..Int64::MAX),
  })

  video_array = playlist_video.to_a
  args = arg_array(video_array)

  PG_DB.exec("INSERT INTO playlist_videos VALUES (#{args})", args: video_array)
  PG_DB.exec("UPDATE playlists SET index = array_append(index, $1), video_count = cardinality(index) + 1, updated = $2 WHERE id = $3", playlist_video.index, Time.utc, plid)

  env.response.headers["Location"] = "#{HOST_URL}/api/v1/auth/playlists/#{plid}/videos/#{playlist_video.index.to_u64.to_s(16).upcase}"
  env.response.status_code = 201
  playlist_video.to_json(locale, index: playlist.index.size)
end

delete "/api/v1/auth/playlists/:plid/videos/:index" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  env.response.content_type = "application/json"
  user = env.get("user").as(User)

  plid = env.params.url["plid"]
  index = env.params.url["index"].to_i64(16)

  playlist = PG_DB.query_one?("SELECT * FROM playlists WHERE id = $1", plid, as: InvidiousPlaylist)
  if !playlist || playlist.author != user.email && playlist.privacy.private?
    next error_json(404, "Playlist does not exist.")
  end

  if playlist.author != user.email
    next error_json(403, "Invalid user")
  end

  if !playlist.index.includes? index
    next error_json(404, "Playlist does not contain index")
  end

  PG_DB.exec("DELETE FROM playlist_videos * WHERE index = $1", index)
  PG_DB.exec("UPDATE playlists SET index = array_remove(index, $1), video_count = cardinality(index) - 1, updated = $2 WHERE id = $3", index, Time.utc, plid)

  env.response.status_code = 204
end

# patch "/api/v1/auth/playlists/:plid/videos/:index" do |env|
# TODO: Playlist stub
# end

get "/api/v1/auth/tokens" do |env|
  env.response.content_type = "application/json"
  user = env.get("user").as(User)
  scopes = env.get("scopes").as(Array(String))

  tokens = PG_DB.query_all("SELECT id, issued FROM session_ids WHERE email = $1", user.email, as: {session: String, issued: Time})

  JSON.build do |json|
    json.array do
      tokens.each do |token|
        json.object do
          json.field "session", token[:session]
          json.field "issued", token[:issued].to_unix
        end
      end
    end
  end
end

post "/api/v1/auth/tokens/register" do |env|
  user = env.get("user").as(User)
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?

  case env.request.headers["Content-Type"]?
  when "application/x-www-form-urlencoded"
    scopes = env.params.body.select { |k, v| k.match(/^scopes\[\d+\]$/) }.map { |k, v| v }
    callback_url = env.params.body["callbackUrl"]?
    expire = env.params.body["expire"]?.try &.to_i?
  when "application/json"
    scopes = env.params.json["scopes"].as(Array).map { |v| v.as_s }
    callback_url = env.params.json["callbackUrl"]?.try &.as(String)
    expire = env.params.json["expire"]?.try &.as(Int64)
  else
    next error_json(400, "Invalid or missing header 'Content-Type'")
  end

  if callback_url && callback_url.empty?
    callback_url = nil
  end

  if callback_url
    callback_url = URI.parse(callback_url)
  end

  if sid = env.get?("sid").try &.as(String)
    env.response.content_type = "text/html"

    csrf_token = generate_response(sid, {":authorize_token"}, HMAC_KEY, PG_DB, use_nonce: true)
    next templated "authorize_token"
  else
    env.response.content_type = "application/json"

    superset_scopes = env.get("scopes").as(Array(String))

    authorized_scopes = [] of String
    scopes.each do |scope|
      if scopes_include_scope(superset_scopes, scope)
        authorized_scopes << scope
      end
    end

    access_token = generate_token(user.email, authorized_scopes, expire, HMAC_KEY, PG_DB)

    if callback_url
      access_token = URI.encode_www_form(access_token)

      if query = callback_url.query
        query = HTTP::Params.parse(query.not_nil!)
      else
        query = HTTP::Params.new
      end

      query["token"] = access_token
      callback_url.query = query.to_s

      env.redirect callback_url.to_s
    else
      access_token
    end
  end
end

post "/api/v1/auth/tokens/unregister" do |env|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  env.response.content_type = "application/json"
  user = env.get("user").as(User)
  scopes = env.get("scopes").as(Array(String))

  session = env.params.json["session"]?.try &.as(String)
  session ||= env.get("session").as(String)

  # Allow tokens to revoke other tokens with correct scope
  if session == env.get("session").as(String)
    PG_DB.exec("DELETE FROM session_ids * WHERE id = $1", session)
  elsif scopes_include_scope(scopes, "GET:tokens")
    PG_DB.exec("DELETE FROM session_ids * WHERE id = $1", session)
  else
    next error_json(400, "Cannot revoke session #{session}")
  end

  env.response.status_code = 204
end

get "/ggpht/*" do |env|
  url = env.request.path.lchop("/ggpht")

  headers = HTTP::Headers{":authority" => "yt3.ggpht.com"}
  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    YT_POOL.client &.get(url, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

options "/sb/:authority/:id/:storyboard/:index" do |env|
  env.response.headers["Access-Control-Allow-Origin"] = "*"
  env.response.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  env.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Range"
end

get "/sb/:authority/:id/:storyboard/:index" do |env|
  authority = env.params.url["authority"]
  id = env.params.url["id"]
  storyboard = env.params.url["storyboard"]
  index = env.params.url["index"]

  url = "/sb/#{id}/#{storyboard}/#{index}?#{env.params.query}"

  headers = HTTP::Headers.new

  headers[":authority"] = "#{authority}.ytimg.com"

  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    YT_POOL.client &.get(url, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Connection"] = "close"
      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

get "/s_p/:id/:name" do |env|
  id = env.params.url["id"]
  name = env.params.url["name"]

  url = env.request.resource

  headers = HTTP::Headers{":authority" => "i9.ytimg.com"}
  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    YT_POOL.client &.get(url, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300 && response.status_code != 404
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

get "/yts/img/:name" do |env|
  headers = HTTP::Headers.new
  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    YT_POOL.client &.get(env.request.resource, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300 && response.status_code != 404
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

get "/vi/:id/:name" do |env|
  id = env.params.url["id"]
  name = env.params.url["name"]

  headers = HTTP::Headers{":authority" => "i.ytimg.com"}

  if name == "maxres.jpg"
    build_thumbnails(id).each do |thumb|
      if YT_POOL.client &.head("/vi/#{id}/#{thumb[:url]}.jpg", headers).status_code == 200
        name = thumb[:url] + ".jpg"
        break
      end
    end
  end
  url = "/vi/#{id}/#{name}"

  REQUEST_HEADERS_WHITELIST.each do |header|
    if env.request.headers[header]?
      headers[header] = env.request.headers[header]
    end
  end

  begin
    YT_POOL.client &.get(url, headers) do |response|
      env.response.status_code = response.status_code
      response.headers.each do |key, value|
        if !RESPONSE_HEADERS_BLACKLIST.includes?(key.downcase)
          env.response.headers[key] = value
        end
      end

      env.response.headers["Access-Control-Allow-Origin"] = "*"

      if response.status_code >= 300 && response.status_code != 404
        env.response.headers.delete("Transfer-Encoding")
        break
      end

      proxy_file(response, env)
    end
  rescue ex
  end
end

get "/Captcha" do |env|
  headers = HTTP::Headers{":authority" => "accounts.google.com"}
  response = YT_POOL.client &.get(env.request.resource, headers)
  env.response.headers["Content-Type"] = response.headers["Content-Type"]
  response.body
end

# Undocumented, creates anonymous playlist with specified 'video_ids', max 50 videos
get "/watch_videos" do |env|
  response = YT_POOL.client &.get(env.request.resource)
  if url = response.headers["Location"]?
    url = URI.parse(url).request_target
    next env.redirect url
  end

  env.response.status_code = response.status_code
end

error 404 do |env|
  if md = env.request.path.match(/^\/(?<id>([a-zA-Z0-9_-]{11})|(\w+))$/)
    item = md["id"]

    # Check if item is branding URL e.g. https://youtube.com/gaming
    response = YT_POOL.client &.get("/#{item}")

    if response.status_code == 301
      response = YT_POOL.client &.get(URI.parse(response.headers["Location"]).request_target)
    end

    if response.body.empty?
      env.response.headers["Location"] = "/"
      halt env, status_code: 302
    end

    html = XML.parse_html(response.body)
    ucid = html.xpath_node(%q(//link[@rel="canonical"])).try &.["href"].split("/")[-1]

    if ucid
      env.response.headers["Location"] = "/channel/#{ucid}"
      halt env, status_code: 302
    end

    params = [] of String
    env.params.query.each do |k, v|
      params << "#{k}=#{v}"
    end
    params = params.join("&")

    url = "/watch?v=#{item}"
    if !params.empty?
      url += "&#{params}"
    end

    # Check if item is video ID
    if item.match(/^[a-zA-Z0-9_-]{11}$/) && YT_POOL.client &.head("/watch?v=#{item}").status_code != 404
      env.response.headers["Location"] = url
      halt env, status_code: 302
    end
  end

  env.response.headers["Location"] = "/"
  halt env, status_code: 302
end

error 500 do |env, ex|
  locale = LOCALES[env.get("preferences").as(Preferences).locale]?
  error_template(500, ex)
end

static_headers do |response, filepath, filestat|
  response.headers.add("Cache-Control", "max-age=2629800")
end

public_folder "assets"

Kemal.config.powered_by_header = false
add_handler FilteredCompressHandler.new
add_handler APIHandler.new
add_handler AuthHandler.new
add_handler DenyFrame.new
add_context_storage_type(Array(String))
add_context_storage_type(Preferences)
add_context_storage_type(User)

Kemal.config.logger = LOGGER
Kemal.config.host_binding = Kemal.config.host_binding != "0.0.0.0" ? Kemal.config.host_binding : CONFIG.host_binding
Kemal.config.port = Kemal.config.port != 3000 ? Kemal.config.port : CONFIG.port
Kemal.run
