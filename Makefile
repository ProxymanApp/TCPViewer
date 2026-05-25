.PHONY: build release beta production nodejs-install

build: release

release:
	cd scripts/nodejs && npm start

beta:
	cd scripts/nodejs && npm start -- --type=beta

production:
	cd scripts/nodejs && npm start -- --type=production

nodejs-install:
	npm install
	cd scripts/nodejs && npm install
