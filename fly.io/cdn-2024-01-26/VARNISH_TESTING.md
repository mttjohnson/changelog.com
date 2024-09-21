# Digital Resin Experimentation

## Build the docker image

We'll need to have a docker image built that we can use

```bash
APP="${PWD##*/}"
#TS="$(date +'%F.%H-%M-%S')"
#IMAGE="registry.fly.io/$APP:$TS"

# If you don't want to rebuild it all the time just staticly set the IMAGE variable
IMAGE="registry.fly.io/cdn-2024-01-26:2024-06-23.14-21-25"
docker buildx build . --tag $IMAGE
```

Inspect the image details:
```bash
docker history --no-trunc --format=json $IMAGE | jq -r .CreatedBy
```

## Run the Varnish container and exec into it

To start the docker container and run the Varnish service:
```bash
docker run --name $APP --volume $PWD/default.vcl:/etc/varnish/default.vcl --rm -itp 9000:9000 $IMAGE
```

In a separate shell exce into the container:
```bash
docker exec -it cdn-2024-01-26 bash
```

## Monitoring the Varnish log

From inside the varnish container run:
```bash
varnishlog
```

## Reload the VCL without restarting

I thought this was super cool! The cache remains intact and you can swap out VCL configs.
https://ma.ttias.be/reload-varnish-vcl-without-losing-cache-data/

```bash
TIME=$(date +%s)
varnishadm vcl.load varnish_$TIME /etc/varnish/default.vcl
varnishadm vcl.use varnish_$TIME
```

A refresh might also be possible using:
```bash
docker exec cdn-2024-01-26 varnishreload
```

This allows you to easily tweak the VCL and try stuff while keeping the cached objects intact.

You can view the list of VCL configs loaded:
```bash
varnishadm vcl.list
```

## Testing the Local Varnish Container

Make a request that should get sent to the defined backend (pipedream.changelog.com)
```bash
curl -s -D - -o /dev/null http://127.0.0.1:9000/shipit/10
curl -s -D - -o /dev/null http://127.0.0.1:9000/friends/38
curl -s -D - -o /dev/null http://127.0.0.1:9000/friends/50
curl -s -D - -o /dev/null http://127.0.0.1:9000/shipit/90
curl -s -D - -o /dev/null http://127.0.0.1:9000/
```

Make a PURGE request that will purge a specific URL from the Varnish cache
```bash
curl -sv -o /dev/null -X PURGE http://127.0.0.1:9000/friends/50
```

Make a BANREGEX request that accepts an HTTP header containing a RegEx to ban objects with. This will ban EVERYTHING `.*` which the ban lurker will later purge.
```bash
curl -sv -o /dev/null -X BANREGEX -H "BanRegexValue:.*" "http://127.0.0.1:9000/"
```

You could also use some rediculous RegEx (`/(?:friends/[123]\d|shipit/[19]0)`) for very specificly targetted objects in the cache, like only the friends episdoes 10-39 and shipit episodes 10 and 90.
```bash
curl -sv -o /dev/null -X BANREGEX -H "BanRegexValue:/(?:friends/[123]\d|shipit/[19]0)" "http://127.0.0.1:9000/"
```

Hit several URLs and check the response's x-cache HTTP header for each
```bash
curl -s -w "%{url.path}: %header{x-cache}\n" -o /dev/null http://127.0.0.1:9000/shipit/10
curl -s -w "%{url.path}: %header{x-cache}\n" -o /dev/null http://127.0.0.1:9000/friends/38
curl -s -w "%{url.path}: %header{x-cache}\n" -o /dev/null http://127.0.0.1:9000/friends/50
curl -s -w "%{url.path}: %header{x-cache}\n" -o /dev/null http://127.0.0.1:9000/shipit/90
curl -s -w "%{url.path}: %header{x-cache}\n" -o /dev/null http://127.0.0.1:9000/
```

For the above 5 example requests the rediculous BANREGEX would ban three of the objects and leave these two in the cache:
```
/shipit/10: MISS
/friends/38: MISS
/friends/50: HIT
/shipit/90: MISS
/: HIT
```

When a ban is created it will be held in a ban list while objects exist in the cache that are older than when the ban was added. You can see the ban list from an exec inside the container:
```bash
varnishadm ban.list
```

## Purging all Varnish instances

It may be possible to have the backend app get a list of the varnish instances using the Fly.io .internal DNS, and get the IPs by querying `cdn-2024-01-26.internal`, then sending a PURGE or BAN request to the varnish instances.

## Other cool things to inspect

I found a couple other cool `varnishadm` commands that looked cool:
```bash
varnishadm backend.list
varnishadm param.show
varnishadm storage.list
```

## ACLs

It will be important to establish an ACL list of hosts that are allowed to submit requests where Varnish will purge or ban cached objects. It looks like fly.io would allow you to identify all the backend apps via the internal dns records `changelog-2024-01-12.internal`, and it's supposed to spit back a list of all the 6PN addresses for that app's instances.

https://fly.io/docs/networking/private-networking/

```vcl
acl local {
    "changelog-2024-01-12.internal";
}
```

I'm not sure if DNS is re-evaluated after the config is loaded, or if Varnish would be able to handle multiple DNS responses in the ACL match, but that is something that will need to be investigated.

```vcl
sub vcl_recv {
  if (req.method == "PURGE") {
    if (client.ip ~ local) {
       return(purge);
    } else {
       return(synth(403, "Access denied."));
    }
  }
}
```

## Dynamic DNS Backends

If the DNS address of the backend resolves to different IPs over time as backends are redeployed we may need something that will update the resolved IP to the DNS address for the backends. It looks like if a hostname is specified in the standard VCL backend, any changes to that hostname will only be picked up if the VCL is reloaded.

https://info.varnish-software.com/blog/two-minutes-tech-tuesdays-dynamic-backend

I found a vmod called ActiveDNS (https://docs.varnish-software.com/varnish-enterprise/vmods/activedns/), that looks to do this, but that is only available to Varnish Enterprise version. Thankfully it also appears there is an open source licensed vmods (dynamic) that perform similar capabilites.

https://varnish-cache.org/vmods/
dynamic https://raw.githubusercontent.com/nigoroll/libvmod-dynamic/master/src/vmod_dynamic.vcc

That ends up leading to how do you get a vmod into the docker container as this is an additional module on top of Varnish that extends the capabilities of Varnish. From a few searches people talk about this being a bit mroe complicated.

https://info.varnish-software.com/blog/varnish-modules-vmods-overview
https://github.com/varnish/docker-varnish/tree/master/vmod-examples

Whiel starting to dig into what is involved in this I noticed some similarities to what I was seeing in the dcoker container history and realized the dynamic vmod is already installed in the official varnish docker container image we are using, and is mentioned on the docker hub page as well (https://hub.docker.com/_/varnish). 😅

The documentation and examples on actually using this vmod_dynamic seems a bit lacking, but I did find a few resources besides the `vmod_dynamic.vcc` file that helped provide a little guidance to piece some of the things together.
https://knplabs.com/en/blog/how2tip-varnish-dynamic-backend-dns-resolution-in-a-docker-swarm-context/
https://medium.com/@archonkulis/varnish-resolves-backend-ip-only-at-launch-time-64b4c103daed

```vcl
import dynamic;

probe backend_probe {
  .url = "/health";
  .timeout = 2s;
  .interval = 5s;
  .window = 10;
  .threshold = 5;
}

backend default {
  .host = "pipedream.changelog.com"; # I think this needs a valid value but isn't used ?
}

sub vcl_init {
  new ddir = dynamic.director(
    ttl = 10s, # the hostname will be resolved every 60 seconds

    # host = "pipedream.changelog.com", # host is defined in vcl_recv call to ddir.backend()
    host_header = "changelog-2024-01-12.fly.dev",
    port = "80",
    first_byte_timeout = 5s,
    probe = backend_probe,
    );
}

sub vcl_recv {
  # use dynamic backend instead of default
  set req.backend_hint = ddir.backend("pipedream.changelog.com");
}
```

Monitoring vmod-dynamic with varnishlog
```bash
varnishlog -g raw -q '* ~ vmod-dynamic'
```
```
         0 Timestamp      - vmod-dynamic varnish_1719685879.ddir(pipedream.changelog.com:80) Lookup: 1719687145.378702 0.000000 0.000000
         0 Timestamp      - vmod-dynamic varnish_1719685879.ddir(pipedream.changelog.com:80) Results: 1719687145.378785 0.000083 0.000083
         0 Timestamp      - vmod-dynamic varnish_1719685879.ddir(pipedream.changelog.com:80) Update: 1719687145.378818 0.000116 0.000032
```

After getting some kind of messy VCL config that I somehow cobbled together, it seems to maybe work, and I found the backend.list is a bit different now with the dynamic backends:
```
varnish@248b1522cf92:/etc/varnish$  varnishadm backend.list
Backend name                                            Admin    Probe  Health   Last change
varnish_1719686569.default                              healthy  0/0    healthy  Sat, 29 Jun 2024 18:42:49 GMT
varnish_1719686569.ddir(pipedream.changelog.com:(null)) probe    1/1    healthy  Sat, 29 Jun 2024 18:43:10 GMT
varnish_1719686569.ddir(188.93.149.98:http)             probe    10/10  healthy  Sat, 29 Jun 2024 18:43:11 GMT
```

Something interesting I think I noticed was that immediately following a reloading the VCL configs there wouldn't be any backends listed. 
```
Backend name               Admin    Probe  Health   Last change
varnish_1719687477.default healthy  0/0    healthy  Sat, 29 Jun 2024 18:57:57 GMT
```
My first request to varnish after the VCL reload would kick off the additional ddir() entries in the backend list and the probe for the IP would start being made. In the `varnishlog` I saw the `ReReq` on that first request would show up with a fetch failure that seemed to imply the specific backend was unhealthy.
```
-   FetchError     backend ddir(188.93.149.98:80): unhealthy
```
checking the backend list shortly after I could see that it had only completed a few of the probes:
```
Backend name                                            Admin    Probe  Health   Last change
varnish_1719687477.default                              healthy  0/0    healthy  Sat, 29 Jun 2024 18:57:57 GMT
varnish_1719687477.ddir(pipedream.changelog.com:(null)) probe    1/1    healthy  Sat, 29 Jun 2024 18:58:14 GMT
varnish_1719687477.ddir(188.93.149.98:80)               probe    5/10   healthy  Sat, 29 Jun 2024 18:58:14 GMT
```
I'm not sure if because I have a probe defined on the backend that the first attempt to it ends up resulting in an unheathy backend because it's dynamically creating the backend during that same request or why exactly it seems to fail, but I thought that was a bit odd. Because I already had a cached object it ended up serving stale content from the cache and after a few seconds was getting successful backend fetches.
```
-   BackendOpen    32 ddir(188.93.149.98:80) 188.93.149.98 80 172.17.0.2 50546 connect
```

I don't feel confident that I know what I'm doing here, but I think it's working... 🤷
