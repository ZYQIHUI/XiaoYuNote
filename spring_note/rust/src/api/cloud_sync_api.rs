use crate::cloud_sync::{
    self, CloudSyncConfig, CloudSyncNoteUploadRequest, CloudSyncRequest, CloudSyncResult,
};

pub async fn test_web_dav_connection(config: CloudSyncConfig) -> CloudSyncResult {
    cloud_sync::test_connection(config).await
}

pub async fn sync_web_dav_notes(request: CloudSyncRequest) -> CloudSyncResult {
    cloud_sync::sync(request).await
}

pub async fn upload_web_dav_note(request: CloudSyncNoteUploadRequest) -> CloudSyncResult {
    cloud_sync::upload_note(request).await
}
