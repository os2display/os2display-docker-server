#!/bin/sh

docker compose --env-file .env.docker.local -f docker-compose.server.yml pull
docker compose --env-file .env.docker.local -f docker-compose.server.yml up --force-recreate --detach --remove-orphans

docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console doctrine:migrations:migrate --no-interaction

echo "NB! Remember to load templates if they have changed. See 'Deployment' in README.md for instructions."
