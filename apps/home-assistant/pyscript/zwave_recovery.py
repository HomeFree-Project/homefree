"""Z-Wave JS node recovery helpers.

Exposes two pyscript services:

  pyscript.recover_zwave_nodes
      Unified per-node recovery pipeline. For each entity_id:
        1. If status is DEAD/UNKNOWN -> rebuild_node_routes
        2. If interview is incomplete (ready=False or manufacturer_id is None)
           -> refresh_info (full re-interview)
        3. Otherwise skip.
      Operates sequentially with `delay_seconds` between nodes.

  pyscript.rebuild_zwave_node_routes
      Legacy alias used by the existing automation; just calls the
      rebuild-routes path of the unified pipeline so old triggers keep
      working.

HA 2026.4 removed the YAML `zwave_js.rebuild_node_routes` and
`zwave_js.refresh_node_info` services -- both operations are now
WebSocket-only. This module re-exposes them as pyscript services so
automations can call them like any other.
"""


def _resolve_node(hass, entity_id):
    """Return (node, error_msg) for the given HA entity_id.

    Imports happen inside the function because pyscript evaluates
    top-level imports under its restricted env; helpers like
    `homeassistant.components.zwave_js.helpers` need allow_all_imports=true.
    """
    from homeassistant.components.zwave_js.helpers import (
        async_get_node_from_entity_id,
    )
    from homeassistant.helpers import device_registry as dr
    from homeassistant.helpers import entity_registry as er

    ent_reg = er.async_get(hass)
    dev_reg = dr.async_get(hass)
    try:
        node = async_get_node_from_entity_id(hass, entity_id, ent_reg, dev_reg)
    except Exception as exc:
        return None, f"resolve failed: {exc}"
    return node, None


def _needs_rebuild(node):
    """Node is unreachable and needs route rebuilding."""
    from zwave_js_server.const import NodeStatus
    return node.status in (NodeStatus.DEAD, NodeStatus.UNKNOWN)


def _needs_reinterview(node):
    """Node is reachable but its interview state is incomplete.

    `ready=False` is the authoritative signal that zwave-js-server is
    still missing CCs / values for this node. `manufacturer_id is None`
    is a defense-in-depth check for nodes that report ready=True but
    have a corrupted cache (the "Unknown manufacturer" log line we
    saw for node 56).
    """
    if not node.ready:
        return True
    if node.manufacturer_id is None:
        return True
    return False


async def _recover_one(node, entity_id):
    """Run the appropriate recovery for a single node. Returns a short
    status string for logging."""
    controller = node.client.driver.controller

    if _needs_rebuild(node):
        log.info(
            "recover_zwave_nodes: %s (node %s) is %s -- rebuilding routes",
            entity_id, node.node_id, node.status.name,
        )
        try:
            result = await controller.async_rebuild_node_routes(node)
            log.info(
                "recover_zwave_nodes: %s (node %s) rebuild result: %s",
                entity_id, node.node_id, result,
            )
        except Exception as exc:
            log.warning(
                "recover_zwave_nodes: %s (node %s) rebuild failed: %s",
                entity_id, node.node_id, exc,
            )
            return "rebuild_failed"

    if _needs_reinterview(node):
        log.info(
            "recover_zwave_nodes: %s (node %s) interview incomplete "
            "(ready=%s manufacturer_id=%s) -- refreshing info",
            entity_id, node.node_id, node.ready, node.manufacturer_id,
        )
        try:
            await node.async_refresh_info()
            log.info(
                "recover_zwave_nodes: %s (node %s) refresh_info requested",
                entity_id, node.node_id,
            )
            return "refreshed"
        except Exception as exc:
            log.warning(
                "recover_zwave_nodes: %s (node %s) refresh_info failed: %s",
                entity_id, node.node_id, exc,
            )
            return "refresh_failed"

    return "ok"


@service
async def recover_zwave_nodes(entity_ids=None, delay_seconds=60):
    """Recover any Z-Wave nodes referenced by entity_ids.

    For each entity:
      - Skip if the node is alive and its interview is complete.
      - Otherwise: rebuild routes (if dead/unknown) and/or refresh
        info (if interview incomplete).

    Operates sequentially with `delay_seconds` between actions because
    the mesh can't handle parallel rebuilds.
    """
    if not entity_ids:
        log.info("recover_zwave_nodes: no entity_ids provided")
        return
    if isinstance(entity_ids, str):
        entity_ids = [entity_ids]

    acted = 0
    for idx, entity_id in enumerate(entity_ids):
        node, err = _resolve_node(hass, entity_id)
        if err:
            log.warning("recover_zwave_nodes: %s -- %s", entity_id, err)
            continue

        status = await _recover_one(node, entity_id)
        if status != "ok":
            acted += 1
            if idx < len(entity_ids) - 1:
                await task.sleep(delay_seconds)

    log.info(
        "recover_zwave_nodes: complete, acted on %s of %s nodes",
        acted, len(entity_ids),
    )


@service
async def rebuild_zwave_node_routes(entity_ids=None, delay_seconds=60):
    """Legacy alias -- delegates to recover_zwave_nodes."""
    await recover_zwave_nodes(entity_ids=entity_ids, delay_seconds=delay_seconds)
