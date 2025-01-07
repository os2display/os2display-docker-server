# OS2display docker server hosting

Basic docker based hosting setup for OS2display v.2

## Deployment

### Containers

Change the tags in .env.docker.local to the tags of the containers you wish to deploy.

E.g.

```dotenv
COMPOSE_VERSION_API=2.0.0
COMPOSE_VERSION_ADMIN=2.0.0
COMPOSE_VERSION_CLIENT=2.0.0
```

### Templates

Import templates and screen layouts:

#### Production

In production run the script `load-templates-prod.sh` with the TEMPLATES_RELEASE environment variable set to the tag of
the templates to load.

E.g.

```shell
TEMPLATES_RELEASE=2.1.0 ./load-templates-prod.sh
```

#### Staging

In staging run the script
