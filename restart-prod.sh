#!/bin/sh

docker-compose --env-file .env.docker.local -f docker-compose.server.yml pull
docker-compose --env-file .env.docker.local -f docker-compose.server.yml up --force-recreate --detach --remove-orphans

docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api composer dump-env prod

docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console doctrine:migrations:migrate --no-interaction

# app:template:load
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/main/build/book-review-config-main.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/main/build/calendar-config-main.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/main/build/contacts-config-main.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/main/build/iframe-config-main.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/main/build/image-text-config-main.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/main/build/instagram-feed-config-main.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/main/build/poster-config-main.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/main/build/rss-config-main.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/main/build/slideshow-config-main.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/main/build/table-config-main.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/main/build/travel-config-main.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:template:load https://raw.githubusercontent.com/os2display/display-templates/main/build/video-config-main.json

# app:screen-layouts:load
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/full-screen.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/three-boxes-horizontal.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/three-boxes.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/touch-template.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/two-boxes.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/two-boxes-vertical.json
docker-compose --env-file .env.docker.local -f docker-compose.server.yml exec --user deploy api bin/console app:screen-layouts:load https://raw.githubusercontent.com/os2display/display-templates/develop/src/screen-layouts/six-areas.json
