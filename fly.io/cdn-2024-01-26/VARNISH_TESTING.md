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
