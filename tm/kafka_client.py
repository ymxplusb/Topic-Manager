"""
Kafka AdminClient wrapper.  All public methods accept a cluster_config dict
and are stateless — a new AdminClient is created per call so the caller never
has to manage connection lifecycle.
"""
from confluent_kafka.admin import (
    AdminClient, NewTopic, ConfigResource, ResourceType,
)
from confluent_kafka import KafkaException


_TIMEOUT = 10  # seconds


def _make_admin(cluster_cfg):
    conf = {
        'bootstrap.servers': cluster_cfg['bootstrap_servers'],
        'security.protocol': cluster_cfg.get('security_protocol', 'PLAINTEXT'),
        'request.timeout.ms': _TIMEOUT * 1000,
        'socket.timeout.ms': _TIMEOUT * 1000,
    }
    sp = conf['security.protocol'].upper()
    if 'SSL' in sp:
        if cluster_cfg.get('ssl_cafile'):
            conf['ssl.ca.location'] = cluster_cfg['ssl_cafile']
        if cluster_cfg.get('ssl_certfile'):
            conf['ssl.certificate.location'] = cluster_cfg['ssl_certfile']
        if cluster_cfg.get('ssl_keyfile'):
            conf['ssl.key.location'] = cluster_cfg['ssl_keyfile']
    if 'SASL' in sp:
        conf['sasl.mechanisms'] = cluster_cfg.get('sasl_mechanism', 'PLAIN')
        conf['sasl.username'] = cluster_cfg.get('sasl_username', '')
        conf['sasl.password'] = cluster_cfg.get('sasl_password', '')
    return AdminClient(conf)


def test_connection(cluster_cfg):
    try:
        admin = _make_admin(cluster_cfg)
        meta = admin.list_topics(timeout=_TIMEOUT)
        brokers = [
            {'id': b.id, 'host': b.host, 'port': b.port}
            for b in meta.brokers.values()
        ]
        return True, {'broker_count': len(brokers), 'brokers': brokers}
    except Exception as exc:
        return False, str(exc)


def get_cluster_metadata(cluster_cfg):
    admin = _make_admin(cluster_cfg)
    meta = admin.list_topics(timeout=_TIMEOUT)
    brokers = [
        {'id': b.id, 'host': b.host, 'port': b.port}
        for b in meta.brokers.values()
    ]
    user_topics = [t for t in meta.topics if not t.startswith('_')]
    return {
        'broker_count': len(brokers),
        'brokers': brokers,
        'topic_count': len(user_topics),
    }


def list_topics(cluster_cfg, include_internal=False):
    admin = _make_admin(cluster_cfg)
    meta = admin.list_topics(timeout=_TIMEOUT)
    topics = []
    for name, tmeta in meta.topics.items():
        is_internal = name.startswith('__') or name.startswith('_schema')
        if is_internal and not include_internal:
            continue
        parts = tmeta.partitions
        rf = len(parts[0].replicas) if parts else 0
        topics.append({
            'name': name,
            'partitions': len(parts),
            'replication_factor': rf,
            'internal': is_internal,
            'error': tmeta.error.str() if tmeta.error else None,
        })
    return sorted(topics, key=lambda t: t['name'])


def get_topic_config(cluster_cfg, topic_name):
    admin = _make_admin(cluster_cfg)
    resource = ConfigResource(ResourceType.TOPIC, topic_name)
    futures = admin.describe_configs([resource])
    result = futures[resource].result()
    configs = {}
    for key, entry in result.items():
        configs[key] = {
            'value': entry.value,
            'is_default': entry.is_default,
            'is_read_only': entry.is_read_only,
        }
    return configs


def create_topic(cluster_cfg, name, partitions, replication_factor, config=None):
    admin = _make_admin(cluster_cfg)
    new_topic = NewTopic(
        topic=name,
        num_partitions=partitions,
        replication_factor=replication_factor,
        config=config or {},
    )
    futures = admin.create_topics([new_topic])
    futures[name].result()


def update_topic_config(cluster_cfg, topic_name, updates):
    """updates: dict of {config_key: new_value}"""
    admin = _make_admin(cluster_cfg)
    resource = ConfigResource(ResourceType.TOPIC, topic_name)
    for key, value in updates.items():
        resource.set_config(key, str(value))
    futures = admin.alter_configs([resource])
    futures[resource].result()


def delete_topic(cluster_cfg, name):
    admin = _make_admin(cluster_cfg)
    futures = admin.delete_topics([name], operation_timeout=_TIMEOUT)
    futures[name].result()


def list_consumer_groups(cluster_cfg):
    admin = _make_admin(cluster_cfg)
    try:
        future = admin.list_consumer_groups()
        result = future.result()
        groups = []
        for g in result.valid:
            groups.append({
                'id': g.group_id,
                'state': g.state.name.title() if hasattr(g.state, 'name') else str(g.state).title(),
                'is_simple': g.is_simple_consumer_group,
            })
        return sorted(groups, key=lambda g: g['id'])
    except Exception as exc:
        raise KafkaException(str(exc))
