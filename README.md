This is made for a school project, and should be easy to spin up locally for most people running the following

Docker compose.
Ubuntu OS - 24.04.
Tailscale vpn mesh.

For the setup you can either 

Run tailscale as a tunnel via tailscale vpn mest, and use the hosting server as a subnet router, and pihole as dns

or

Set up Wireguard and duckdns, with the compose files. #with this approach you need to change the compose and env files accordingly, not included in the current setup.

