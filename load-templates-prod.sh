#!/bin/sh

if [ -z "${TEMPLATES_RELEASE}" ]
then
  echo "TEMPLATES_RELEASE must be set to a valid tag."
  exit 2
fi

echo "Loading templates with tag: ${TEMPLATES_RELEASE}."

# app:template:load
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load -p https://raw.githubusercontent.com/os2display/display-templates/refs/tags/${TEMPLATES_RELEASE}/build/book-review-config-main.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load -p https://raw.githubusercontent.com/os2display/display-templates/refs/tags/${TEMPLATES_RELEASE}/build/calendar-config-main.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load -p https://raw.githubusercontent.com/os2display/display-templates/refs/tags/${TEMPLATES_RELEASE}/build/contacts-config-main.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load -p https://raw.githubusercontent.com/os2display/display-templates/refs/tags/${TEMPLATES_RELEASE}/build/iframe-config-main.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load -p https://raw.githubusercontent.com/os2display/display-templates/refs/tags/${TEMPLATES_RELEASE}/build/image-text-config-main.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load -p https://raw.githubusercontent.com/os2display/display-templates/refs/tags/${TEMPLATES_RELEASE}/build/instagram-feed-config-main.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load -p https://raw.githubusercontent.com/os2display/display-templates/refs/tags/${TEMPLATES_RELEASE}/build/news-feed-config-main.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load -p https://raw.githubusercontent.com/os2display/display-templates/refs/tags/${TEMPLATES_RELEASE}/build/poster-config-main.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load -p https://raw.githubusercontent.com/os2display/display-templates/refs/tags/${TEMPLATES_RELEASE}/build/rss-config-main.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load -p https://raw.githubusercontent.com/os2display/display-templates/refs/tags/${TEMPLATES_RELEASE}/build/slideshow-config-main.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load -p https://raw.githubusercontent.com/os2display/display-templates/refs/tags/${TEMPLATES_RELEASE}/build/table-config-main.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load -p https://raw.githubusercontent.com/os2display/display-templates/refs/tags/${TEMPLATES_RELEASE}/build/travel-config-main.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load -p https://raw.githubusercontent.com/os2display/display-templates/refs/tags/${TEMPLATES_RELEASE}/build/video-config-main.json

# app:screen-layouts:load
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load --update --cleanup-regions https://raw.githubusercontent.com/os2display/display-templates/main/src/screen-layouts/full-screen.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load --update --cleanup-regions https://raw.githubusercontent.com/os2display/display-templates/main/src/screen-layouts/three-boxes-horizontal.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load --update --cleanup-regions https://raw.githubusercontent.com/os2display/display-templates/main/src/screen-layouts/three-boxes.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load --update --cleanup-regions https://raw.githubusercontent.com/os2display/display-templates/main/src/screen-layouts/touch-template.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load --update --cleanup-regions https://raw.githubusercontent.com/os2display/display-templates/main/src/screen-layouts/two-boxes.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load --update --cleanup-regions https://raw.githubusercontent.com/os2display/display-templates/main/src/screen-layouts/two-boxes-vertical.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load --update --cleanup-regions https://raw.githubusercontent.com/os2display/display-templates/main/src/screen-layouts/six-areas.json
docker compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load --update --cleanup-regions https://raw.githubusercontent.com/os2display/display-templates/main/src/screen-layouts/four-areas.json
