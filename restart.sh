#!/bin/sh

docker-compose --env-file .env.docker.local -f docker-compose.server.yml pull
docker-compose --env-file .env.docker.local -f docker-compose.server.yml up --force-recreate --detach --remove-orphans

docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console doctrine:migrations:migrate --no-interaction
# 2022-03-14: Keys are now persisteted in volume 
# docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console lexik:jwt:generate-keypair

# app:template:load
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/build/book-review-config-develop.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/build/calendar-config-develop.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/build/contacts-config-develop.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/build/iframe-config-develop.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/build/image-text-config-develop.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/build/instagram-feed-config-develop.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/build/poster-config-develop.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/build/rss-config-develop.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/build/slideshow-config-develop.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/build/table-config-develop.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/build/travel-config-develop.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/build/video-config-develop.json
# app:screen-layouts:load
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/full-screen.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/three-boxes-horizontal.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/three-boxes.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/touch-template.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/two-boxes.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/two-boxes-vertical.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/six-areas.json
