#
# This file is part of Astarte.
#
# Copyright 2017 - 2025 SECO Mind Srl
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

defmodule Astarte.VMQ.PluginTest do
  use Astarte.VMQ.Plugin.Test.Cases.Database, async: true
  use Astarte.VMQ.Plugin.Test.Cases.AMQP, async: true
  use ExUnitProperties

  doctest Astarte.VMQ.Plugin

  alias AMQP.Queue
  alias Astarte.VMQ.Plugin
  alias Astarte.VMQ.Plugin.Test.Helpers.Database
  alias Astarte.VMQ.Plugin.Test.Helpers.AMQP, as: AMQPHelper
  alias Astarte.Core.Generators.Device, as: DeviceGenerator
  alias Astarte.Common.Generators.Ip, as: IpGenerator
  alias Astarte.Core.Generators.Interface, as: InterfaceGenerator
  alias Astarte.VMQ.Plugin.Test.Helpers.TopicGenerator
  alias Astarte.VMQ.Plugin.Test.Helpers.PayloadGenerator
  alias Astarte.VMQ.Plugin.Test.Helpers.Device, as: DeviceHelper
  alias Astarte.VMQ.Plugin.Test.Fixtures.Device, as: DeviceFixture

  # 5 seconds in tenths of microsecond
  @max_timestamp_difference :timer.seconds(5) * 10_0000

  describe "auth_on_register" do
    @describetag :auth_on_register

    @tag :integration
    @tag :database
    test "succeeds for existing devices", %{realm_name: realm_name} do
      device_id = DeviceHelper.random_device()
      Database.insert_device_into_devices!(realm_name, device_id)
      device_base_path = "#{realm_name}/#{device_id}"

      assert {:ok, modifiers} =
               Plugin.auth_on_register(
                 :dontcare,
                 {"/", :dontcare},
                 device_base_path,
                 :dontcare,
                 :dontcare
               )

      assert Keyword.get(modifiers, :subscriber_id) == {"/", device_base_path}
      _ = Database.cleanup_db!(realm_name)
    end

    @tag :integration
    @tag :database
    property "fails for existing devices that are being deleted", %{realm_name: realm_name} do
      device_under_deletion = DeviceHelper.random_device()
      Database.insert_device_into_devices!(realm_name, device_under_deletion)
      Database.insert_device_into_deletion_in_progress!(realm_name, device_under_deletion)

      assert {:error, :device_deletion_in_progress} =
               Plugin.auth_on_register(
                 :dontcare,
                 {"/", :dontcare},
                 "#{realm_name}/#{device_under_deletion}",
                 :dontcare,
                 :dontcare
               )

      Database.cleanup_db!(realm_name)
    end

    @tag :unit
    property "fails for non-existing devices", %{realm_name: realm_name} do
      check all(non_existing_device_id <- DeviceGenerator.encoded_id()) do
        assert {:error, :device_does_not_exist} =
                 Plugin.auth_on_register(
                   :dontcare,
                   {"/", :dontcare},
                   "#{realm_name}/#{non_existing_device_id}",
                   :dontcare,
                   :dontcare
                 )
      end
    end

    @tag :unit
    test "ignores non-devices" do
      assert :next =
               Plugin.auth_on_register(
                 :dontcare,
                 {"/", :dontcare},
                 DeviceFixture.not_a_device_id(),
                 :dontcare,
                 :dontcare
               )
    end
  end

  describe "auth_on_subscribe" do
    @describetag :unit
    @describetag :auth_on_subscribe

    property "succeeds on authorized topics", %{realm_name: realm} do
      device_id = DeviceHelper.random_device()
      device_base_path = "#{realm}/#{device_id}"

      check all(
              topics <-
                list_of(TopicGenerator.mqtt_topic(prefix: "#{device_base_path}/"), min_length: 1),
              topic_tokens = Enum.map(topics, &String.split(&1, "/", trim: true)),
              qos <- list_of(integer(0..2), min_length: 1)
            ) do
        topic_tokens_with_qos = Enum.zip(topic_tokens, qos)

        assert {:ok, ^topic_tokens_with_qos} =
                 Plugin.auth_on_subscribe(
                   :dontcare,
                   {:dontcare, device_base_path},
                   topic_tokens_with_qos
                 )
      end
    end

    property "fails on unauthorized topics", %{realm_name: realm} do
      authorized_device_id = DeviceHelper.random_device()
      authorized_base_path = "#{realm}/#{authorized_device_id}"

      check all(
              topics <- list_of(TopicGenerator.mqtt_topic(), min_length: 1),
              topic_tokens = Enum.map(topics, &String.split(&1, "/", trim: true)),
              qos <- list_of(integer(0..2), min_length: 1)
            ) do
        unauthorized_topics = Enum.zip(topic_tokens, qos)

        assert {:error, :unauthorized} =
                 Plugin.auth_on_subscribe(
                   :dontcare,
                   {:dontcare, authorized_base_path},
                   unauthorized_topics
                 )
      end
    end

    property "filters out unauthorized topics", %{realm_name: realm} do
      authorized_device_id = DeviceHelper.random_device()
      authorized_base_path = "#{realm}/#{authorized_device_id}"

      check all(
              topics <- list_of(TopicGenerator.mqtt_topic(), min_length: 1),
              topic_tokens = Enum.map(topics, &String.split(&1, "/", trim: true)),
              qos <- list_of(integer(0..2), min_length: 1)
            ) do
        authorized_topics = [
          {[realm, authorized_device_id, "authorizedtopic"], 2},
          {[realm, authorized_device_id, "otherauthorizedtopic"], 1}
        ]

        unauthorized_topics = Enum.zip(topic_tokens, qos)

        all_topics = authorized_topics ++ unauthorized_topics

        assert {:ok, ^authorized_topics} =
                 Plugin.auth_on_subscribe(
                   :dontcare,
                   {:dontcare, authorized_base_path},
                   all_topics
                 )
      end
    end

    property "ignores topics not related to devices" do
      check all(
              topics <- list_of(TopicGenerator.mqtt_topic(), min_length: 1),
              topic_tokens = Enum.map(topics, &String.split(&1, "/", trim: true)),
              qos <- list_of(integer(0..2), min_length: 1)
            ) do
        topics = Enum.zip(topic_tokens, qos)

        assert :next =
                 Plugin.auth_on_subscribe(
                   :dontcare,
                   {:dontcare, DeviceFixture.not_a_device_id()},
                   topics
                 )
      end
    end
  end

  describe "auth_on_publish" do
    @describetag :unit
    @describetag :auth_on_publish

    property "succeeds on authorized topics", %{realm_name: realm} do
      device_id = DeviceHelper.random_device()
      device_base_path = "#{realm}/#{device_id}"

      check all(topic <- TopicGenerator.mqtt_topic(prefix: "#{device_base_path}/"), min_length: 1) do
        topic_tokens = String.split(topic, "/", trim: true)

        assert :ok =
                 Plugin.auth_on_publish(
                   :dontcare,
                   {:dontcare, device_base_path},
                   :dontcare,
                   topic_tokens,
                   :dontcare,
                   :dontcare
                 )
      end
    end

    test "succeeds on device_base_path topic", %{realm_name: realm} do
      device_id = DeviceHelper.random_device()
      device_base_path = "#{realm}/#{device_id}"
      topic = [realm, device_id]

      assert :ok =
               Plugin.auth_on_publish(
                 :dontcare,
                 {:dontcare, device_base_path},
                 :dontcare,
                 topic,
                 :dontcare,
                 :dontcare
               )
    end

    property "fails on unauthorized topics", %{realm_name: realm} do
      authorized_device_id = DeviceHelper.random_device()
      authorized_base_path = "#{realm}/#{authorized_device_id}"

      check all(topics <- list_of(TopicGenerator.mqtt_topic(), min_length: 1)) do
        topic_tokens = Enum.map(topics, &String.split(&1, "/", trim: true))

        assert {:error, :unauthorized} =
                 Plugin.auth_on_publish(
                   :dontcare,
                   {:dontcare, authorized_base_path},
                   :dontcare,
                   topic_tokens,
                   :dontcare,
                   :dontcare
                 )
      end
    end

    test "ignores non-devices" do
      not_a_device_id = DeviceFixture.not_a_device_id()

      check all(topics <- list_of(TopicGenerator.mqtt_topic(), min_length: 1)) do
        topic_tokens = Enum.map(topics, &String.split(&1, "/", trim: true))

        assert :next =
                 Plugin.auth_on_publish(
                   :dontcare,
                   {:dontcare, not_a_device_id},
                   :dontcare,
                   topic_tokens,
                   :dontcare,
                   :dontcare
                 )
      end
    end
  end

  describe "Device messages to AMQP:" do
    @describetag :integration
    @describetag :amqp

    setup %{chan: chan, realm_name: realm_name} do
      test_pid = self()
      encoded_device_id = DeviceHelper.random_device()
      queue_name = AMQPHelper.setup_device_queue!(chan, realm_name, encoded_device_id)
      consumer_tag = AMQPHelper.setup_consumer!(test_pid, chan, queue_name)

      on_exit(fn -> Queue.unsubscribe(chan, consumer_tag) end)
      {:ok, %{device_id: encoded_device_id}}
    end

    @tag :on_register
    test "registration generates a connection message", %{
      realm_name: realm,
      device_id: device_id
    } do
      check all(ip <- IpGenerator.ip(:ipv4)) do
        ip_string = :inet.ntoa(ip) |> to_string()
        Plugin.on_register({ip, :dontcare}, {:dontcare, "#{realm}/#{device_id}"}, :dontcare)

        assert_receive {:amqp_msg, "",
                        %{headers: headers, timestamp: timestamp, message_id: message_id} =
                          _metadata}

        assert_in_delta timestamp, now_us_x10_timestamp(), @max_timestamp_difference

        assert %{
                 "x_astarte_vmqamqp_proto_ver" => 1,
                 "x_astarte_msg_type" => "connection",
                 "x_astarte_realm" => ^realm,
                 "x_astarte_device_id" => ^device_id,
                 "x_astarte_remote_ip" => ^ip_string
               } = amqp_headers_to_map(headers)

        assert String.starts_with?(message_id, message_id_prefix(realm, device_id, timestamp))
      end
    end

    @tag :on_client_gone
    test "on_client_gone generates a disconnection message", %{
      realm_name: realm,
      device_id: device_id
    } do
      Plugin.on_client_gone({:dontcare, "#{realm}/#{device_id}"})

      assert_receive {:amqp_msg, "",
                      %{headers: headers, timestamp: timestamp, message_id: message_id} =
                        _metadata}

      assert_in_delta timestamp, now_us_x10_timestamp(), @max_timestamp_difference

      assert %{
               "x_astarte_vmqamqp_proto_ver" => 1,
               "x_astarte_msg_type" => "disconnection",
               "x_astarte_realm" => ^realm,
               "x_astarte_device_id" => ^device_id
             } = amqp_headers_to_map(headers)

      assert String.starts_with?(message_id, message_id_prefix(realm, device_id, timestamp))
    end

    @tag :on_client_offline
    test "on_client_offline generates a disconnection message", %{
      realm_name: realm,
      device_id: device_id
    } do
      Plugin.on_client_offline({:dontcare, "#{realm}/#{device_id}"})

      assert_receive {:amqp_msg, "",
                      %{headers: headers, timestamp: timestamp, message_id: message_id} =
                        _metadata}

      assert_in_delta timestamp, now_us_x10_timestamp(), @max_timestamp_difference

      assert %{
               "x_astarte_vmqamqp_proto_ver" => 1,
               "x_astarte_msg_type" => "disconnection",
               "x_astarte_realm" => ^realm,
               "x_astarte_device_id" => ^device_id
             } = amqp_headers_to_map(headers)

      assert String.starts_with?(message_id, message_id_prefix(realm, device_id, timestamp))
    end

    @tag :on_publish
    property "publish introspection generates an introspection message", %{
      realm_name: realm,
      device_id: device_id
    } do
      check all(interfaces <- list_of(InterfaceGenerator.interface())) do
        payload = generate_introspection_payload(interfaces)
        device_base_path = "#{realm}/#{device_id}"
        introspection_topic = [realm, device_id]

        Plugin.on_publish(
          :dontcare,
          {:dontcare, device_base_path},
          :dontcare,
          introspection_topic,
          payload,
          :dontcare
        )

        assert_receive {:amqp_msg, ^payload,
                        %{headers: headers, timestamp: timestamp, message_id: message_id} =
                          _metadata}

        assert_in_delta timestamp, now_us_x10_timestamp(), @max_timestamp_difference

        assert %{
                 "x_astarte_vmqamqp_proto_ver" => 1,
                 "x_astarte_msg_type" => "introspection",
                 "x_astarte_realm" => ^realm,
                 "x_astarte_device_id" => ^device_id
               } = amqp_headers_to_map(headers)

        assert String.starts_with?(message_id, message_id_prefix(realm, device_id, timestamp))
      end
    end

    @tag :on_publish
    property "publish control message generates a control message", %{
      realm_name: realm,
      device_id: device_id
    } do
      check all(control_topic <- TopicGenerator.control_topic(realm, device_id)) do
        device_base_path = "#{realm}/#{device_id}"
        control_base_path = "#{device_base_path}/control"
        topic_tokens = String.split(control_topic, "/", trim: true)
        path_header = String.replace_prefix(control_topic, control_base_path, "")
        payload = "payload"

        Plugin.on_publish(
          :dontcare,
          {:dontcare, device_base_path},
          :dontcare,
          topic_tokens,
          payload,
          :dontcare
        )

        assert_receive {:amqp_msg, ^payload,
                        %{headers: headers, timestamp: timestamp, message_id: message_id} =
                          _metadata}

        assert_in_delta timestamp, now_us_x10_timestamp(), @max_timestamp_difference

        assert %{
                 "x_astarte_vmqamqp_proto_ver" => 1,
                 "x_astarte_msg_type" => "control",
                 "x_astarte_realm" => ^realm,
                 "x_astarte_device_id" => ^device_id,
                 "x_astarte_control_path" => ^path_header
               } = amqp_headers_to_map(headers)

        assert String.starts_with?(message_id, message_id_prefix(realm, device_id, timestamp))
      end
    end

    @tag :on_publish
    property "publish data generates a data message", %{
      realm_name: realm,
      device_id: device_id
    } do
      check all(
              interface <- InterfaceGenerator.interface(),
              data_topic <- TopicGenerator.data_topic(realm, device_id, interface.name),
              # Don't care for the type right now
              payload <- PayloadGenerator.payload()
            ) do
        device_base_path = "#{realm}/#{device_id}"
        data_base_path = "#{device_base_path}/#{interface.name}"
        topic_tokens = String.split(data_topic, "/", trim: true)
        interface_header = interface.name
        path_header = String.replace_prefix(data_topic, data_base_path, "")

        Plugin.on_publish(
          :dontcare,
          {:dontcare, device_base_path},
          :dontcare,
          topic_tokens,
          payload,
          :dontcare
        )

        assert_receive {:amqp_msg, ^payload,
                        %{headers: headers, timestamp: timestamp, message_id: message_id} =
                          _metadata}

        assert_in_delta timestamp, now_us_x10_timestamp(), @max_timestamp_difference

        assert %{
                 "x_astarte_vmqamqp_proto_ver" => 1,
                 "x_astarte_msg_type" => "data",
                 "x_astarte_realm" => ^realm,
                 "x_astarte_device_id" => ^device_id,
                 "x_astarte_interface" => ^interface_header,
                 "x_astarte_path" => ^path_header
               } = amqp_headers_to_map(headers)

        assert String.starts_with?(message_id, message_id_prefix(realm, device_id, timestamp))
      end
    end
  end

  describe "Clients that are not devices" do
    @describetag :integration
    @describetag :amqp

    setup do
      %{
        not_a_device_id: DeviceFixture.not_a_device_id(),
        device_id: DeviceHelper.random_device()
      }
    end

    @tag :on_connection
    property "do not generate connection messages on_connection", context do
      check all(ip <- IpGenerator.ip(:ipv4)) do
        Plugin.on_register({ip, :dontcare}, {:dontcare, context.not_a_device_id}, :dontcare)
        refute_receive {:amqp_msg, _payload, _meta}
      end
    end

    @tag :on_client_gone
    test "do not generate disconnection message on_client_gone", context do
      Plugin.on_client_gone({:dontcare, context.not_a_device_id})
      refute_receive {:amqp_msg, _payload, _meta}
    end

    @tag :on_client_offline
    test "do not generate disconnection message on_client_offline", context do
      Plugin.on_client_offline({:dontcare, context.not_a_device_id})
      refute_receive {:amqp_msg, _payload, _meta}
    end

    @tag :on_publish
    property "do not generate introspection message on_publish", context do
      introspection_topic = [context.realm_name, context.device_id]

      check all(interfaces <- list_of(InterfaceGenerator.interface())) do
        introspection_payload = generate_introspection_payload(interfaces)

        Plugin.on_publish(
          :dontcare,
          {:dontcare, context.not_a_device_id},
          :dontcare,
          introspection_topic,
          introspection_payload,
          :dontcare
        )

        refute_receive {:amqp_msg, _payload, _meta}
      end
    end

    @tag :on_publish
    property "do not generate control message on_publish", context do
      check all(
              control_topic <-
                TopicGenerator.control_topic(context.realm_name, context.device_id),
              payload <- PayloadGenerator.payload()
            ) do
        topic_tokens = String.split(control_topic, "/", trim: true)

        Plugin.on_publish(
          :dontcare,
          {:dontcare, context.not_a_device_id},
          :dontcare,
          topic_tokens,
          payload,
          :dontcare
        )

        refute_receive {:amqp_msg, _payload, _meta}
      end
    end

    @tag :on_publish
    test "do not generate data message on_publish", context do
      interface = "com.my.Interface"

      check all(
              data_topic <-
                TopicGenerator.data_topic(context.realm_name, context.device_id, interface)
            ) do
        topic_tokens = String.split(data_topic, "/", trim: true)

        data_payload = "a payload"

        Plugin.on_publish(
          :dontcare,
          {:dontcare, context.not_a_device_id},
          :dontcare,
          topic_tokens,
          data_payload,
          :dontcare
        )

        refute_receive {:amqp_msg, _payload, _meta}
      end
    end
  end

  describe "handle_heartbeat" do
    @describetag :integration
    @describetag :amqp
    @describetag :handle_heartbeat

    setup %{chan: chan, realm_name: realm_name} do
      test_pid = self()
      encoded_device_id = DeviceHelper.random_device()
      queue_name = AMQPHelper.setup_device_queue!(chan, realm_name, encoded_device_id)
      consumer_tag = AMQPHelper.setup_consumer!(test_pid, chan, queue_name)

      on_exit(fn -> Queue.unsubscribe(chan, consumer_tag) end)
      {:ok, %{device_id: encoded_device_id}}
    end

    test "works with an alive session_pid", %{
      realm_name: realm,
      device_id: device_id
    } do
      # Check it works with a currently alive process
      alive_process = self()
      :ok = Plugin.handle_heartbeat(realm, device_id, alive_process)

      assert_receive {:amqp_msg, "",
                      %{headers: headers, timestamp: timestamp, message_id: message_id} =
                        _metadata}

      assert_in_delta timestamp, now_us_x10_timestamp(), @max_timestamp_difference

      assert %{
               "x_astarte_vmqamqp_proto_ver" => 1,
               "x_astarte_msg_type" => "internal",
               "x_astarte_realm" => ^realm,
               "x_astarte_device_id" => ^device_id,
               "x_astarte_internal_path" => "/heartbeat"
             } = amqp_headers_to_map(headers)

      assert String.starts_with?(message_id, message_id_prefix(realm, device_id, timestamp))
    end

    test "does not publish if the session_pid is not alive", %{
      realm_name: realm,
      device_id: device_id
    } do
      dead_process = spawn(fn -> 42 end)

      # Make sure the dead process returns
      :timer.sleep(100)

      :ok = Plugin.handle_heartbeat(realm, device_id, dead_process)

      refute_receive {:amqp_msg, _payload, _meta}
    end
  end

  describe "disconnection and connection events are correctly serialized" do
    @describetag :integration
    @describetag :amqp
    @describetag :connection_serialization

    setup %{chan: chan, realm_name: realm_name} do
      test_pid = self()
      encoded_device_id = DeviceHelper.random_device()
      queue_name = AMQPHelper.setup_device_queue!(chan, realm_name, encoded_device_id)
      consumer_tag = AMQPHelper.setup_consumer!(test_pid, chan, queue_name)

      on_exit(fn -> Queue.unsubscribe(chan, consumer_tag) end)
      {:ok, %{device_id: encoded_device_id}}
    end

    @tag :on_register_before_on_client_offline
    test "when on_register is called just before on_client_offline", %{
      realm_name: realm,
      device_id: device_id
    } do
      device_base_path = "#{realm}/#{device_id}"
      ip_addr = {2, 3, 4, 5}

      Task.start(Plugin, :on_register, [
        {ip_addr, :dontcare},
        {:dontcare, device_base_path},
        :dontcare
      ])

      # Call hook in another process, as VMQ does
      Task.start(Plugin, :on_client_offline, [{:dontcare, device_base_path}])

      # First, disconnection is received...
      assert_receive {:amqp_msg, "",
                      %{
                        headers: disconnection_headers,
                        timestamp: disconnection_timestamp,
                        message_id: disconnection_message_id
                      }}

      assert %{
               "x_astarte_vmqamqp_proto_ver" => 1,
               "x_astarte_msg_type" => "disconnection",
               "x_astarte_realm" => ^realm,
               "x_astarte_device_id" => ^device_id
             } = amqp_headers_to_map(disconnection_headers)

      assert String.starts_with?(
               disconnection_message_id,
               message_id_prefix(realm, device_id, disconnection_timestamp)
             )

      # ... and only after, reconnection
      assert_receive {:amqp_msg, "",
                      %{
                        headers: connection_headers,
                        timestamp: connection_timestamp,
                        message_id: connection_message_id
                      }}

      assert %{
               "x_astarte_vmqamqp_proto_ver" => 1,
               "x_astarte_msg_type" => "connection",
               "x_astarte_realm" => ^realm,
               "x_astarte_device_id" => ^device_id,
               "x_astarte_remote_ip" => "2.3.4.5"
             } = amqp_headers_to_map(connection_headers)

      assert String.starts_with?(
               connection_message_id,
               message_id_prefix(realm, device_id, connection_timestamp)
             )
    end

    @tag :on_register_before_on_client_gone
    test "when on_register is called just before on_client_gone", %{
      realm_name: realm,
      device_id: device_id
    } do
      device_base_path = "#{realm}/#{device_id}"
      ip_addr = {2, 3, 4, 5}

      Task.start(Plugin, :on_register, [
        {ip_addr, :dontcare},
        {:dontcare, device_base_path},
        :dontcare
      ])

      # Call hook in another process, as VMQ does
      Task.start(Plugin, :on_client_gone, [{:dontcare, device_base_path}])

      # First, disconnection is received...
      assert_receive {:amqp_msg, "",
                      %{
                        headers: disconnection_headers,
                        timestamp: disconnection_timestamp,
                        message_id: disconnection_message_id
                      }}

      assert %{
               "x_astarte_vmqamqp_proto_ver" => 1,
               "x_astarte_msg_type" => "disconnection",
               "x_astarte_realm" => ^realm,
               "x_astarte_device_id" => ^device_id
             } = amqp_headers_to_map(disconnection_headers)

      assert String.starts_with?(
               disconnection_message_id,
               message_id_prefix(realm, device_id, disconnection_timestamp)
             )

      # ... and only after, reconnection
      assert_receive {:amqp_msg, "",
                      %{
                        headers: connection_headers,
                        timestamp: connection_timestamp,
                        message_id: connection_message_id
                      }}

      assert %{
               "x_astarte_vmqamqp_proto_ver" => 1,
               "x_astarte_msg_type" => "connection",
               "x_astarte_realm" => ^realm,
               "x_astarte_device_id" => ^device_id,
               "x_astarte_remote_ip" => "2.3.4.5"
             } = amqp_headers_to_map(connection_headers)

      assert String.starts_with?(
               connection_message_id,
               message_id_prefix(realm, device_id, connection_timestamp)
             )
    end

    @tag :on_client_offline_before_on_register
    test "when on_client_offline is called before on_register", %{
      realm_name: realm,
      device_id: device_id
    } do
      device_base_path = "#{realm}/#{device_id}"
      ip_addr = {2, 3, 4, 5}

      # Call hook in another process, as VMQ does
      Task.start(Plugin, :on_client_offline, [{:dontcare, device_base_path}])

      # Call hook in another process, as VMQ does
      Task.start(Plugin, :on_register, [
        {ip_addr, :dontcare},
        {:dontcare, device_base_path},
        :dontcare
      ])

      # First, disconnection is received...
      assert_receive {:amqp_msg, "",
                      %{
                        headers: disconnection_headers,
                        timestamp: disconnection_timestamp,
                        message_id: disconnection_message_id
                      }}

      assert %{
               "x_astarte_vmqamqp_proto_ver" => 1,
               "x_astarte_msg_type" => "disconnection",
               "x_astarte_realm" => ^realm,
               "x_astarte_device_id" => ^device_id
             } = amqp_headers_to_map(disconnection_headers)

      assert String.starts_with?(
               disconnection_message_id,
               message_id_prefix(realm, device_id, disconnection_timestamp)
             )

      # ... and only after, reconnection
      assert_receive {:amqp_msg, "",
                      %{
                        headers: connection_headers,
                        timestamp: connection_timestamp,
                        message_id: connection_message_id
                      }}

      assert %{
               "x_astarte_vmqamqp_proto_ver" => 1,
               "x_astarte_msg_type" => "connection",
               "x_astarte_realm" => ^realm,
               "x_astarte_device_id" => ^device_id,
               "x_astarte_remote_ip" => "2.3.4.5"
             } = amqp_headers_to_map(connection_headers)

      assert String.starts_with?(
               connection_message_id,
               message_id_prefix(realm, device_id, connection_timestamp)
             )
    end

    @tag :on_client_gone_before_on_register
    test "when on_client_gone is called before on_register", %{
      realm_name: realm,
      device_id: device_id
    } do
      device_base_path = "#{realm}/#{device_id}"
      ip_addr = {2, 3, 4, 5}

      # Call hook in another process, as VMQ does
      Task.start(Plugin, :on_client_gone, [{:dontcare, device_base_path}])

      # Call hook in another process, as VMQ does
      Task.start(Plugin, :on_register, [
        {ip_addr, :dontcare},
        {:dontcare, device_base_path},
        :dontcare
      ])

      # First, disconnection is received...
      assert_receive {:amqp_msg, "",
                      %{
                        headers: disconnection_headers,
                        timestamp: disconnection_timestamp,
                        message_id: disconnection_message_id
                      }}

      assert %{
               "x_astarte_vmqamqp_proto_ver" => 1,
               "x_astarte_msg_type" => "disconnection",
               "x_astarte_realm" => ^realm,
               "x_astarte_device_id" => ^device_id
             } = amqp_headers_to_map(disconnection_headers)

      assert String.starts_with?(
               disconnection_message_id,
               message_id_prefix(realm, device_id, disconnection_timestamp)
             )

      # ... and only after, reconnection
      assert_receive {:amqp_msg, "",
                      %{
                        headers: connection_headers,
                        timestamp: connection_timestamp,
                        message_id: connection_message_id
                      }}

      assert %{
               "x_astarte_vmqamqp_proto_ver" => 1,
               "x_astarte_msg_type" => "connection",
               "x_astarte_realm" => ^realm,
               "x_astarte_device_id" => ^device_id,
               "x_astarte_remote_ip" => "2.3.4.5"
             } = amqp_headers_to_map(connection_headers)

      assert String.starts_with?(
               connection_message_id,
               message_id_prefix(realm, device_id, connection_timestamp)
             )
    end
  end

  defp amqp_headers_to_map(headers) do
    Enum.reduce(headers, %{}, fn {key, _type, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  defp now_us_x10_timestamp do
    DateTime.utc_now()
    |> DateTime.to_unix(:microsecond)
    |> Kernel.*(10)
  end

  defp message_id_prefix(realm, device_id, timestamp) do
    realm_trunc = String.slice(realm, 0..63)
    device_id_trunc = String.slice(device_id, 0..15)
    timestamp_hex_str = Integer.to_string(timestamp, 16)
    "#{realm_trunc}-#{device_id_trunc}-#{timestamp_hex_str}-"
  end

  defp generate_introspection_payload(interfaces) do
    interfaces
    |> Enum.map(fn interface ->
      "#{interface.name}:#{interface.version_major}:#{interface.version_minor}"
    end)
    |> Enum.join(";")
  end
end
