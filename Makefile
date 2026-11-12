build-LiveRegistration:
	mkdir -p "$(ARTIFACTS_DIR)/aws/apns-training" "$(ARTIFACTS_DIR)/server/monitoring" "$(ARTIFACTS_DIR)/nigeyo-ios/Nigeyo/Resources"
	cp aws/live-registration.mjs "$(ARTIFACTS_DIR)/aws/"
	cp aws/apns-training/index.mjs "$(ARTIFACTS_DIR)/aws/apns-training/"
	cp server/monitoring/regions.mjs "$(ARTIFACTS_DIR)/server/monitoring/"
	cp nigeyo-ios/Nigeyo/Resources/notification-regions-aichi.json nigeyo-ios/Nigeyo/Resources/notification-regions-national.json "$(ARTIFACTS_DIR)/nigeyo-ios/Nigeyo/Resources/"
