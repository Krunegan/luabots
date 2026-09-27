-- Hello world: say hi and show some robot info
chat.nearby("Hello! I am " .. robot.name() .. ", robot of " .. robot.owner())
print("My position:", vector.to_string(robot.pos()))
print("Facing:", robot.facing())
print("Level:", robot.level())

for i = 1, 3 do
	robot.sound("beep")
	sleep(0.5)
end
robot.label("Hi!")
