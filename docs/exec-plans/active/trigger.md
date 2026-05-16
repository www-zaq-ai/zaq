I want to change the way trigger are working in the current branch for the workflow.

I want to identify a new rule to the NodeRouter this will help us pass all events to the engine. So the NodeRouter will be doing business as usual like sending events from any Node to another node but also every event will be send to the engine using PubSub.

On the engine side we will have a process that is subscribed to the PubSub event and will get all the events that passes through the NodeRouter. This process will be responsible to store these events in the state. Key is the event name and boolean value indicating if the event is a trigger or not.

So when this process is up by the engine supervisor it will check the trigger DB table and load all the events and make them true. Otherwise when there is a new event it is stored in the state of this process.

So now when this process have an event that is true it will fire the trigger in that way we have a loose and decoupled trigger system.

For manual trigger the event name will be :manual_trigger that is dispatch from the BO from a NodeRouter with :noop so it reaches the NodeRouter and then the engine.

For the trigger we will have a new type of node called TriggerNode that will be responsible to fire the trigger. So the TriggerNode is responsible to get all triggers from the DB and fire them in parallel. So all workflows will be executed.

So make sure to delete all the trigger logic from the current branch and implement the new trigger system.
