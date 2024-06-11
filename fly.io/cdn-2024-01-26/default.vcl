# specify the VCL syntax version to use
vcl 4.1;

backend default {
    .host = "changelog-2024-01-12.fly.dev";
    .host_header = "changelog-2024-01-12.fly.dev";
    .port = "443";
    .ssl = 1;
    .ssl_sni = 1;
    .ssl_verify_peer = 1;
    .ssl_verify_host = 1;
    .first_byte_timeout = 5s;
    .probe = {
        .url = "/health";
        .timeout = 2s;
        .interval = 5s;
        .window = 10;
        .threshold = 5;
   }
}

sub vcl_recv {
  # https://varnish-cache.org/docs/trunk/users-guide/purging.html
  if (req.method == "PURGE") {
    return (purge);
  }
}

# TODOS:
# - ✅ Run in debug mode
# - Configure HTTPS for app backend
# - Store cache on disk: https://varnish-cache.org/docs/trunk/users-guide/storage-backends.html#file
# - Add Feeds backend: /feed -> https://feeds.changelog.place/feed.xml
#
# FOLLOW-UPs:
# - Run varnishncsa as a separate process (will need a supervisor + log drain)
# - Configure health probe on the backend

# LINKS: Thanks Matt Johnson!
# - https://github.com/magento/magento2/blob/03621bbcd75cbac4ffa8266a51aa2606980f4830/app/code/Magento/PageCache/etc/varnish6.vcl
# - https://abhishekjakhotiya.medium.com/magento-internals-cache-purging-and-cache-tags-bf7772e60797
# - https://varnish-cache.org/intro/index.html#intro
