use workspace::{Appearance, SessionItem, WorkspaceContent, WorkspaceSnapshot};

#[test]
fn projects_config_and_inventory_into_ui_only_values() {
    let snapshot = WorkspaceSnapshot::ready(
        Appearance::default(),
        "Ubuntu",
        vec![SessionItem::new("editor", 1)],
    );

    assert_eq!(snapshot.appearance().font_family(), "Cascadia Mono");
    let WorkspaceContent::Ready { endpoint, sessions } = snapshot.content() else {
        panic!("expected ready workspace");
    };
    assert_eq!(endpoint, "Ubuntu");
    assert_eq!(sessions[0].name(), "editor");
    assert_eq!(sessions[0].attached_clients(), 1);
}
