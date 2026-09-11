#!/usr/bin/env python3
"""
Redis Cluster 数据迁移工具
支持：
  1. 集群 → JSON 文件（导出）
  2. 集群 → SQLite 数据库（导出）
  3. JSON 文件 → 集群（导入）
  4. SQLite 数据库 → 集群（导入）

用法：
  # 导出到 JSON
  python redis_cluster_migrate.py export --host 127.0.0.1 --port 7000 --password xxx --format json --output data.json

  # 导出到 SQLite
  python redis_cluster_migrate.py export --host 127.0.0.1 --port 7000 --password xxx --format sqlite --output data.db

  # 从 JSON 导入
  python redis_cluster_migrate.py import --host 127.0.0.1 --port 7000 --password xxx --format json --input data.json

  # 从 SQLite 导入
  python redis_cluster_migrate.py import --host 127.0.0.1 --port 7000 --password xxx --format sqlite --input data.db
"""

import argparse
import json
import sqlite3
import sys
import time
import base64
import pickle

import redis
from redis.cluster import RedisCluster, ClusterNode


# ──────────────────────────────────────────────
# 工具函数
# ──────────────────────────────────────────────

def get_cluster_client(host, port, password=None, ssl=False):
    """创建 Redis Cluster 客户端"""
    startup_nodes = [ClusterNode(host, int(port))]
    client = RedisCluster(
        startup_nodes=startup_nodes,
        password=password,
        decode_responses=False,
        ssl=ssl,
        socket_timeout=10,
        socket_connect_timeout=10,
        retry_on_timeout=True,
    )
    return client


def serialize_value(value):
    """将 Redis 值序列化为可存储的格式"""
    if isinstance(value, bytes):
        return {"type": "bytes", "data": base64.b64encode(value).decode("ascii")}
    return {"type": "str", "data": value}


def deserialize_value(obj):
    """反序列化"""
    if obj["type"] == "bytes":
        return base64.b64decode(obj["data"])
    return obj["data"]


def dump_key_data(client, key):
    """
    导出单个 key 的完整数据（类型、值、TTL）
    支持 string / hash / list / set / zset / stream 等类型
    """
    key_type = client.type(key).decode('utf-8')
    if key_type == "none":
        return None

    ttl = client.ttl(key)  # -1=无过期, -2=已过期/不存在

    data = {
        "key": key,
        "type": key_type,
        "ttl": ttl,
        "value": None,
    }

    if key_type == "string":
        data["value"] = serialize_value(client.get(key))

    elif key_type == "hash":
        raw = client.hgetall(key)
        data["value"] = {
            serialize_value(k)["data"]: serialize_value(v)
            for k, v in raw.items()
        }

    elif key_type == "list":
        items = client.lrange(key, 0, -1)
        data["value"] = [serialize_value(item) for item in items]

    elif key_type == "set":
        members = client.smembers(key)
        data["value"] = [serialize_value(m) for m in members]

    elif key_type == "zset":
        # 获取所有成员及其分数
        members = client.zrange(key, 0, -1, withscores=True)
        data["value"] = [
            {"member": serialize_value(m), "score": score}
            for m, score in members
        ]

    elif key_type == "stream":
        # 导出 stream 的所有消息
        messages = client.xrange(key, "-", "+")
        data["value"] = [
            {
                "message_id": msg_id,
                "fields": {
                    serialize_value(k)["data"]: serialize_value(v)
                    for k, v in fields.items()
                }
            }
            for msg_id, fields in messages
        ]

    else:
        print(f"  [WARN] 未知类型 '{key_type}'，跳过 key: {key}")
        return None

    return data


def restore_key_data(client, record, batch_size=200):
    """
    将一条记录写回 Redis Cluster
    """
    key = record["key"]
    key_type = record["type"]
    ttl = record["ttl"]
    value = record["value"]

    # 先删除已有 key，避免冲突
    client.delete(key)

    if key_type == "string":
        client.set(key, deserialize_value(value))

    elif key_type == "hash":
        mapping = {k: deserialize_value(v) for k, v in value.items()}
        if mapping:
            client.hmset(key, mapping)

    elif key_type == "list":
        items = [deserialize_value(item) for item in value]
        if items:
            client.rpush(key, *items)

    elif key_type == "set":
        members = [deserialize_value(m) for m in value]
        if members:
            client.sadd(key, *members)

    elif key_type == "zset":
        for entry in value:
            member = deserialize_value(entry["member"])
            score = entry["score"]
            client.zadd(key, {member: score})

    elif key_type == "stream":
        for msg in value:
            fields = {k: deserialize_value(v) for k, v in msg["fields"].items()}
            client.xadd(key, fields, id=msg["message_id"])

    # 恢复 TTL
    if ttl and ttl > 0:
        client.expire(key, ttl)


# ──────────────────────────────────────────────
# 导出：集群 → 文件/SQLite
# ──────────────────────────────────────────────

def export_cluster(client, output_path, fmt, pattern="*", args_password=None, batch_size=500):
    """
    遍历集群所有节点，使用 SCAN 导出全部 key
    """
    print(f"开始导出 Redis Cluster 数据...")
    print(f"  目标: {output_path} (格式: {fmt})")

    # 获取所有 master 节点
    primaries = client.get_primaries()
    total_keys = 0

    if fmt == "json":
        out_file = open(output_path, "w", encoding="utf-8")
        out_file.write("[\n")
        first = True

    elif fmt == "sqlite":
        conn = sqlite3.connect(output_path)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS redis_data (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                key TEXT NOT NULL,
                type TEXT NOT NULL,
                ttl INTEGER,
                value_json TEXT NOT NULL
            )
        """)
        conn.execute("DELETE FROM redis_data")  # 清空旧数据
        conn.commit()

    try:
        # 直接使用集群客户端的 scan_iter，自动处理所有路由和 MOVED
        for key in client.scan_iter(match=pattern, count=batch_size):
            # 为每个 master 节点创建独立连接

            # node_client = redis.Redis( # 单机
            #     host=node.host,
            #     port=node.port,
            #     password=client.connection_pool.connection_kwargs.get("password"),
            #     decode_responses=True,
            #     socket_timeout=10,
            # )  

            # while True:
            #     cursor, keys = node_client.scan(
            #         cursor=cursor, match=pattern, count=batch_size
            #     )
                # for key in keys:
                    try:
                        record = dump_key_data(client, key)
                        if record is None:
                            continue

                        if fmt == "json":
                            if not first:
                                out_file.write(",\n")
                            json.dump(record, out_file, ensure_ascii=False)
                            first = False

                        elif fmt == "sqlite":
                            conn.execute(
                                "INSERT INTO redis_data (key, type, ttl, value_json) VALUES (?, ?, ?, ?)",
                                (record["key"], record["type"], record["ttl"],
                                 json.dumps(record["value"], ensure_ascii=False))
                            )

                        # node_keys += 1
                        total_keys += 1

                        if total_keys % 1000 == 0:
                            print(f"    已导出 {total_keys} 个 key...")

                    except Exception as e:
                        print(f"    [ERROR] 导出 key '{key}' 失败: {e}")

                # if cursor == 0:
                #     break

        # print(f"  节点 {node.host}:{node.port} 导出完成，共 {node_keys} 个 key")

    finally:
        if fmt == "json":
            out_file.write("\n]\n")
            out_file.close()
        elif fmt == "sqlite":
            conn.commit()
            conn.close()

    print(f"\n导出完成！共导出 {total_keys} 个 key")


# ──────────────────────────────────────────────
# 导入：文件/SQLite → 集群
# ──────────────────────────────────────────────

def import_to_cluster(client, input_path, fmt,args_password, batch_size=200):
    """
    从 JSON 文件或 SQLite 读取数据并写入集群
    """
    print(f"开始导入数据到 Redis Cluster...")
    print(f"  来源: {input_path} (格式: {fmt})")

    total = 0
    errors = 0

    if fmt == "json":
        with open(input_path, "r", encoding="utf-8") as f:
            records = json.load(f)

        for record in records:
            try:
                restore_key_data(client, record)
                total += 1
                if total % 1000 == 0:
                    print(f"  已导入 {total} 个 key...")
            except Exception as e:
                errors += 1
                print(f"  [ERROR] 导入 key '{record.get('key')}' 失败: {e}")

    elif fmt == "sqlite":
        conn = sqlite3.connect(input_path)
        conn.row_factory = sqlite3.Row
        cursor = conn.execute("SELECT id,key, type, ttl, value_json FROM redis_data ORDER BY id")

        for row in cursor:
            record = { 
                "key": row["key"],
                "type": row["type"],
                "ttl": row["ttl"],
                "value": json.loads(row["value_json"]),
            }
            try:
                restore_key_data(client, record)
                total += 1
                if total % 1000 == 0:
                    print(f"  已导入 {total} 个 key...")
            except Exception as e:
                errors += 1
                print(f"  [ERROR] 导入 key '{record.get('key')}' id '{row["id"]}' 失败: {e}")
                print(f"  [ERROR] 导入 json_v '{record.get('value')}' va '{row["value_json"]}' 失败: {e}")


        conn.close()

    print(f"\n导入完成！成功: {total}，失败: {errors}")


# ──────────────────────────────────────────────
# 主入口
# ──────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Redis Cluster 数据迁移工具（导出/导入）"
    )
    subparsers = parser.add_subparsers(dest="command" )

    # ── export 子命令 ──
    export_parser = subparsers.add_parser("export", help="从集群导出数据")
    export_parser.add_argument("--host" , help="集群任一节点 IP")
    export_parser.add_argument("--port" , type=int, help="集群任一节点端口")
    export_parser.add_argument("--password", default=None, help="Redis 密码")
    export_parser.add_argument("--ssl", action="store_true", help="启用 SSL")
    export_parser.add_argument("--format", choices=["json", "sqlite"] , help="导出格式")
    export_parser.add_argument("--output" , help="输出文件路径")
    export_parser.add_argument("--pattern", default="*", help="key 匹配模式，默认 *")

    # ── import 子命令 ──
    import_parser = subparsers.add_parser("import", help="导入数据到集群")
    import_parser.add_argument("--host" , help="目标集群任一节点 IP")
    import_parser.add_argument("--port" , type=int, help="目标集群任一节点端口")
    import_parser.add_argument("--password", default=None, help="Redis 密码")
    import_parser.add_argument("--ssl", action="store_true", help="启用 SSL")
    import_parser.add_argument("--format", choices=["json", "sqlite"] , help="导入格式")
    import_parser.add_argument("--input" , help="输入文件路径")

    args = parser.parse_args()

    # 创建集群客户端
    client = get_cluster_client(args.host, args.port, args.password, args.ssl)

    if args.command == "export":
        export_cluster(client, args.output, args.format, args.pattern,args.password)
    elif args.command == "import":
        import_to_cluster(client, args.input, args.format,args.password,args.password)


if __name__ == "__main__":
    main()