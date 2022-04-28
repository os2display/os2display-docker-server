#!/bin/sh

docker-compose --env-file .env.docker.local -f docker-compose.server.yml pull
docker-compose --env-file .env.docker.local -f docker-compose.server.yml up --force-recreate --detach --remove-orphans

docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console doctrine:migrations:migrate --no-interaction
# 2022-03-14: Keys are now persisteted in volume 
# docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console lexik:jwt:generate-keypair

# app:template:load
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/book-review/book-review.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/calendar/calendar.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/contacts/contacts.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/iframe/iframe.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/image-text/image-text.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/instagram-feed/instagram-feed.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/poster/poster.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/rss/rss.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/slideshow/slideshow.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/table/table.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/video/video.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/develop/build/travel/travel.json

# app:screen-layouts:load
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/full-screen.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/three-boxes-horizontal.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/three-boxes.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/touch-template.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/two-boxes.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/two-boxes-vertical.json